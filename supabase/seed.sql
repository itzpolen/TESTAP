

-- Admin bootstrap only. No sample data.
-- 1. Supabase Dashboard > Authentication > Users > Add user (tick Auto Confirm User).
-- 2. Put that user's real email below, then run this once in the SQL Editor.
begin;

do $$
declare
  admin_email constant text := 'aquadirectadmin123@gmail.com';  -- change this
  admin_user uuid;
begin
  select id into admin_user from auth.users where lower(email) = lower(admin_email);
  if admin_user is null then
    raise exception 'Create the Auth user % first', admin_email;
  end if;

  insert into public.profiles (id, full_name)
  values (admin_user, 'AquaDirect Admin')
  on conflict (id) do update set full_name = excluded.full_name;

  insert into public.user_roles (user_id, role)
  values (admin_user, 'admin')
  on conflict (user_id, role) do nothing;
end;
$$;

commit;