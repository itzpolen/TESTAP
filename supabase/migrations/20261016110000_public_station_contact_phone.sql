create or replace function public.get_public_station_phone(p_station_id uuid)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select s.phone
  from public.stations s
  where s.id = p_station_id
    and public.is_public_station(s.id);
$$;

grant execute on function public.get_public_station_phone(uuid) to anon, authenticated;
