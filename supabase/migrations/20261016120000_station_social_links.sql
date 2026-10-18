alter table public.stations
  add column if not exists facebook_url text,
  add column if not exists instagram_url text,
  add constraint stations_facebook_url_check check (
    facebook_url is null or facebook_url ~*
      '^https://([a-z0-9-]+\.)*(facebook\.com|fb\.com)(:[0-9]+)?([/?#]|$)'
  ),
  add constraint stations_instagram_url_check check (
    instagram_url is null or instagram_url ~*
      '^https://([a-z0-9-]+\.)*instagram\.com(:[0-9]+)?([/?#]|$)'
  );

create or replace function public.get_public_station_social_links(p_station_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'facebook_url', s.facebook_url,
    'instagram_url', s.instagram_url
  )
  from public.stations s
  where s.id = p_station_id
    and public.is_public_station(s.id);
$$;

revoke execute on function public.get_public_station_social_links(uuid) from public;
grant execute on function public.get_public_station_social_links(uuid) to anon, authenticated;
