create table if not exists public.station_order_dismissals (
  user_id uuid not null references public.profiles(id) on delete cascade,
  order_id uuid not null references public.orders(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, order_id)
);

alter table public.station_order_dismissals enable row level security;

drop policy if exists "Station members manage their order dismissals"
  on public.station_order_dismissals;
create policy "Station members manage their order dismissals"
  on public.station_order_dismissals for all to authenticated
  using (
    user_id = (select auth.uid())
    and exists (
      select 1 from public.orders o
      where o.id = order_id
        and (select public.is_station_member(o.station_id))
    )
  )
  with check (
    user_id = (select auth.uid())
    and exists (
      select 1 from public.orders o
      where o.id = order_id
        and (select public.is_station_member(o.station_id))
    )
  );

grant select, insert, delete on public.station_order_dismissals to authenticated;

drop policy if exists "Customers station members and admins view orders"
  on public.orders;
create policy "Customers station members and admins view orders"
  on public.orders for select to authenticated
  using (
    customer_id = (select auth.uid())
    or (select public.is_station_member(station_id))
    or public.is_order_party(id)
    or (select public.is_admin())
    or (select public.has_permission('support.manage'))
    or (select public.has_permission('payments.view'))
  );

drop policy if exists "Order parties view order items"
  on public.order_items;
create policy "Order parties view order items"
  on public.order_items for select to authenticated
  using (
    public.is_order_party(order_id)
    or exists (
      select 1
      from public.orders o
      where o.id = order_id
        and (select public.is_station_member(o.station_id))
    )
    or (select public.is_admin())
    or (select public.has_permission('support.manage'))
    or (select public.has_permission('payments.view'))
  );

create or replace view public.station_order_payment_status
with (security_barrier = true)
as
select distinct on (o.id)
  o.id as order_id,
  p.method as payment_method,
  p.status as payment_status,
  p.amount,
  p.updated_at
from public.orders o
join public.payments p on p.order_id = o.id
where public.is_station_member(o.station_id)
order by o.id, p.created_at desc;

grant select on public.station_order_payment_status to authenticated;
