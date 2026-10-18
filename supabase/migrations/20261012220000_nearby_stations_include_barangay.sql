create or replace function public.nearby_stations_with_barangay(
  p_latitude double precision,
  p_longitude double precision,
  p_radius_km double precision default 25,
  p_filters jsonb default '{}'::jsonb,
  p_page_size integer default 20,
  p_page_offset integer default 0
)
returns table (
  station_id uuid,
  display_name text,
  description text,
  logo_path text,
  barangay text,
  city text,
  province text,
  latitude double precision,
  longitude double precision,
  distance_km double precision,
  starting_price numeric,
  estimated_delivery_minutes integer,
  is_open boolean,
  rating_average numeric,
  rating_count integer
)
language sql
stable
security definer
set search_path = ''
as $$
  select
    nearby.station_id,
    nearby.display_name,
    nearby.description,
    nearby.logo_path,
    station.barangay,
    nearby.city,
    nearby.province,
    nearby.latitude,
    nearby.longitude,
    nearby.distance_km,
    nearby.starting_price,
    nearby.estimated_delivery_minutes,
    nearby.is_open,
    nearby.rating_average,
    nearby.rating_count
  from public.nearby_stations(
    p_latitude,
    p_longitude,
    p_radius_km,
    p_filters,
    p_page_size,
    p_page_offset
  ) as nearby
  join public.stations as station on station.id = nearby.station_id;
$$;

grant execute on function public.nearby_stations_with_barangay(
  double precision,
  double precision,
  double precision,
  jsonb,
  integer,
  integer
) to anon, authenticated;
