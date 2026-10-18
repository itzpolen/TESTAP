create or replace function public.submit_application(p_application_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  application_row public.station_applications%rowtype;
  station_row public.stations%rowtype;
  required_documents integer;
begin
  if auth.uid() is null then
    raise exception 'Authentication is required';
  end if;

  select * into application_row
  from public.station_applications
  where id = p_application_id and owner_id = auth.uid()
  for update;

  if not found then
    raise exception 'Station application was not found';
  end if;
  if application_row.application_status not in ('draft', 'changes_requested') then
    raise exception 'Only draft or returned applications can be submitted';
  end if;
  if nullif(btrim(application_row.legal_business_name), '') is null
    or nullif(btrim(application_row.display_name), '') is null
    or nullif(btrim(application_row.phone), '') is null
    or nullif(btrim(application_row.address_line), '') is null
    or nullif(btrim(application_row.city), '') is null
    or nullif(btrim(application_row.province), '') is null
  then
    raise exception 'Complete all required station profile fields before submitting';
  end if;
  if application_row.latitude is null or application_row.longitude is null then
    raise exception 'A valid station map location is required before submitting';
  end if;

  select * into station_row
  from public.stations
  where application_id = p_application_id;
  if not found then
    raise exception 'Complete station setup before submitting';
  end if;
  if station_row.service_radius_km is null or station_row.service_radius_km <= 0 then
    raise exception 'Set a delivery radius greater than zero before submitting';
  end if;
  if station_row.default_delivery_fee is null or station_row.default_delivery_fee < 0
    or station_row.minimum_order_amount is null or station_row.minimum_order_amount < 0
  then
    raise exception 'Set valid delivery fees and minimum order before submitting';
  end if;
  if not exists (
    select 1 from public.station_products p
    where p.station_id = station_row.id and p.status = 'active'
  ) then
    raise exception 'Add at least one active water product before submitting';
  end if;
  if exists (
    select 1
    from public.station_products p
    where p.station_id = station_row.id
      and p.status = 'active'
      and not exists (
        select 1 from public.container_policies cp
        where cp.station_id = p.station_id
          and cp.container_type_id = p.container_type_id
          and cp.is_active
      )
  ) then
    raise exception 'Save an active container policy for every active product before submitting';
  end if;
  if not exists (
    select 1
    from public.station_operating_hours h
    where h.station_id = station_row.id
      and not h.is_closed
      and h.opens_at is not null
      and h.closes_at is not null
      and h.opens_at <> h.closes_at
  ) then
    raise exception 'Set at least one valid open day before submitting';
  end if;

  select count(*) into required_documents
  from public.station_document_requirements r
  where r.application_id = p_application_id and r.required;

  if required_documents = 0 or exists (
    select 1
    from public.station_document_requirements r
    where r.application_id = p_application_id
      and r.required
      and not exists (
        select 1 from public.station_documents d
        where d.application_id = r.application_id
          and d.document_type = r.document_type
          and d.is_current
          and d.required_for_verification
      )
  ) then
    raise exception 'Upload every required document type before submitting';
  end if;

  if exists (
    select 1
    from public.station_documents d
    where d.application_id = p_application_id
      and d.is_current
      and d.required_for_verification
      and (
        d.review_status = 'rejected'
        or not exists (
          select 1 from storage.objects so
          where so.bucket_id = 'station-documents'
            and so.name = d.storage_path
        )
        or (
          d.document_type = 'business_permit'
          and (d.expires_at is null or d.expires_at <= current_date)
        )
        or d.expires_at is not null and d.expires_at <= current_date
      )
  ) then
    raise exception 'Every current required document must exist in private storage and be unexpired';
  end if;

  perform set_config('app.submit_application', 'on', true);
  update public.station_applications
  set application_status = 'submitted',
      verification_status = 'pending',
      submitted_at = now()
  where id = p_application_id;
  perform set_config('app.station_review', 'on', true);
  update public.stations
  set verification_status = 'pending'
  where application_id = p_application_id;
  perform set_config('app.station_review', 'off', true);
  perform set_config('app.submit_application', 'off', true);
end;
$$;
