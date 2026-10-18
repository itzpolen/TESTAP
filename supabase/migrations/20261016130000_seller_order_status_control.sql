create or replace function public.enforce_order_transition()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  transition_allowed boolean := false;
begin
  if new.status = old.status then
    return new;
  end if;

  transition_allowed := case old.status
    when 'pending' then new.status in ('confirmed', 'cancelled', 'failed')
    when 'confirmed' then new.status in ('preparing', 'cancelled', 'failed')
    when 'preparing' then new.status in ('ready', 'cancelled', 'failed')
    when 'ready' then new.status in ('rider_assigned', 'delivered', 'cancelled', 'failed')
    when 'rider_assigned' then new.status in ('out_for_delivery', 'cancelled', 'failed')
    when 'out_for_delivery' then new.status in ('delivered', 'failed')
    else false
  end;

  if not transition_allowed then
    raise exception 'Invalid order status transition: % -> %', old.status, new.status;
  end if;

  if current_setting('app.order_transition', true) is distinct from 'on'
    and coalesce(auth.role(), '') <> 'service_role'
  then
    raise exception 'Order status changes require an authorized function';
  end if;

  insert into public.order_status_history (
    order_id, old_status, new_status, changed_by, note
  )
  values (
    new.id,
    old.status,
    new.status,
    auth.uid(),
    coalesce(
      nullif(current_setting('app.order_transition_note', true), ''),
      new.cancel_reason
    )
  );

  return new;
end;
$$;

create or replace function public.expire_unaccepted_cod_orders()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
begin
  if coalesce(auth.role(), '') <> 'service_role'
    and not exists (
      select 1 from pg_catalog.pg_roles
      where rolname = current_user and (rolsuper or rolbypassrls)
    )
  then
    raise exception 'Unaccepted order expiry is restricted to trusted servers';
  end if;

  return 0;
end;
$$;

create or replace function public.expire_unaccepted_paid_orders()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
begin
  if coalesce(auth.role(), '') <> 'service_role'
    and not exists (
      select 1 from pg_catalog.pg_roles
      where rolname = current_user and (rolsuper or rolbypassrls)
    )
  then
    raise exception 'Unaccepted paid order expiry is restricted to trusted servers';
  end if;

  return 0;
end;
$$;

comment on function public.expire_unaccepted_cod_orders() is
  'Order status is seller-controlled; unaccepted COD orders are not auto-cancelled.';
comment on function public.expire_unaccepted_paid_orders() is
  'Order status is seller-controlled; paid orders are not auto-cancelled or auto-refunded for non-acceptance.';

do $$
begin
  if not exists (
    select 1 from pg_catalog.pg_publication
    where pubname = 'supabase_realtime'
  ) then
    create publication supabase_realtime;
  end if;
  if not exists (
    select 1 from pg_catalog.pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'orders'
  ) then
    alter publication supabase_realtime add table public.orders;
  end if;
end;
$$;

create or replace function public.cancel_station_order(
  p_order_id uuid,
  p_reason text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  order_row public.orders%rowtype;
  payment_row public.payments%rowtype;
  payment_found boolean := false;
  refunded_amount numeric(12, 2);
  refundable numeric(12, 2);
  refund_id_value uuid;
  reason_value text := nullif(trim(p_reason), '');
begin
  if auth.uid() is null then
    raise exception 'Authentication is required';
  end if;
  if reason_value is null then
    raise exception 'A cancellation reason is required';
  end if;

  select * into order_row
  from public.orders
  where id = p_order_id
  for update;
  if not found or not public.is_station_member(order_row.station_id) then
    raise exception 'Order was not found for this station';
  end if;
  if order_row.status not in ('pending', 'confirmed', 'preparing', 'ready', 'rider_assigned') then
    raise exception 'This order can no longer be cancelled by the station';
  end if;

  select * into payment_row
  from public.payments
  where order_id = p_order_id
  order by attempt_number desc
  limit 1
  for update;
  payment_found := found;

  if payment_found and payment_row.status in ('paid', 'partially_refunded') then
    if payment_row.provider is distinct from 'paymongo'
      or payment_row.provider_payment_id is null
    then
      raise exception 'This paid order requires administrator refund assistance before cancellation';
    end if;

    select coalesce(sum(pr.amount), 0) into refunded_amount
    from public.payment_refunds pr
    where pr.payment_id = payment_row.id
      and pr.status in ('requested', 'processing', 'succeeded');
    refundable := payment_row.amount - refunded_amount;

    if refundable > 0 then
      refund_id_value := null;
      insert into public.payment_refunds (
        payment_id, requested_by, amount, status, reason, idempotency_key
      )
      values (
        payment_row.id, auth.uid(), refundable, 'requested',
        'Station cancellation: ' || reason_value,
        'station-cancel-refund:' || p_order_id::text
      )
      on conflict (idempotency_key) do nothing
      returning id into refund_id_value;

      if refund_id_value is null then
        select pr.id into refund_id_value
        from public.payment_refunds pr
        where pr.idempotency_key = 'station-cancel-refund:' || p_order_id::text;
      end if;

      insert into public.payment_provider_actions (
        payment_id, refund_id, action_type, idempotency_key, payload
      )
      values (
        payment_row.id, refund_id_value, 'refund',
        'execute-refund:' || refund_id_value::text,
        jsonb_build_object(
          'provider', payment_row.provider,
          'provider_payment_id', payment_row.provider_payment_id,
          'amount', refundable,
          'reason', 'Station cancellation: ' || reason_value
        )
      )
      on conflict (idempotency_key) do nothing;
    end if;
  elsif payment_found
    and payment_row.status in ('pending', 'processing')
    and payment_row.provider = 'paymongo'
    and payment_row.provider_checkout_id is not null
  then
    insert into public.payment_provider_actions (
      payment_id, action_type, idempotency_key, payload
    )
    values (
      payment_row.id, 'expire_checkout',
      'expire-checkout:' || payment_row.id::text,
      jsonb_build_object(
        'provider', payment_row.provider,
        'provider_checkout_id', payment_row.provider_checkout_id,
        'order_id', p_order_id
      )
    )
    on conflict (idempotency_key) do nothing;
  end if;

  perform set_config('app.order_transition_note', reason_value, true);
  perform set_config('app.order_transition', 'on', true);
  update public.orders
  set status = 'cancelled',
      cancelled_at = now(),
      cancel_reason = reason_value,
      cancelled_by = auth.uid()
  where id = p_order_id;
  perform set_config('app.order_transition', 'off', true);
  perform set_config('app.order_transition_note', '', true);

  perform set_config('app.payment_transition', 'on', true);
  update public.payments
  set status = 'cancelled'
  where order_id = p_order_id
    and status in ('pending', 'processing');
  perform set_config('app.payment_transition', 'off', true);

  update public.deliveries
  set status = 'cancelled'
  where order_id = p_order_id
    and status not in ('delivered', 'failed', 'cancelled');

  perform set_config('app.release_inventory', 'on', true);
  perform public.release_order_inventory(p_order_id, reason_value);
  perform set_config('app.release_inventory', 'off', true);
end;
$$;
