drop policy if exists "Customers dismiss their cancelled orders"
  on public.customer_order_dismissals;
drop policy if exists "Customers hide completed orders"
  on public.customer_order_dismissals;
drop policy if exists "Customers hide their orders"
  on public.customer_order_dismissals;
drop policy if exists "Customers hide finished orders"
  on public.customer_order_dismissals;

delete from public.customer_order_dismissals d
using public.orders o
where o.id = d.order_id
  and o.status not in ('delivered', 'cancelled');

create policy "Customers hide finished orders"
  on public.customer_order_dismissals for insert to authenticated
  with check (
    user_id = (select auth.uid())
    and exists (
      select 1
      from public.orders o
      where o.id = order_id
        and o.customer_id = (select auth.uid())
        and o.status in ('delivered', 'cancelled')
    )
  );

drop policy if exists "Station members manage their order dismissals"
  on public.station_order_dismissals;

delete from public.station_order_dismissals d
using public.orders o
where o.id = d.order_id
  and o.status not in ('delivered', 'cancelled');

create policy "Station members manage their order dismissals"
  on public.station_order_dismissals for all to authenticated
  using (
    user_id = (select auth.uid())
    and exists (
      select 1
      from public.orders o
      where o.id = order_id
        and (select public.is_station_member(o.station_id))
    )
  )
  with check (
    user_id = (select auth.uid())
    and exists (
      select 1
      from public.orders o
      where o.id = order_id
        and (select public.is_station_member(o.station_id))
        and o.status in ('delivered', 'cancelled')
    )
  );
