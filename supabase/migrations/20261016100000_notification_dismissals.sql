alter table public.notifications
  add column if not exists dismissed_at timestamptz;

create or replace function public.protect_notification_update()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.user_id is distinct from old.user_id
    or new.title is distinct from old.title
    or new.body is distinct from old.body
    or new.notification_type is distinct from old.notification_type
    or new.data is distinct from old.data
    or new.created_at is distinct from old.created_at
    or (
      new.dismissed_at is distinct from old.dismissed_at
      and new.dismissed_at is null
    )
  then
    raise exception 'Users may only mark notifications as read or dismissed';
  end if;
  return new;
end;
$$;
