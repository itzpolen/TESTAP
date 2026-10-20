drop policy if exists "Customers dismiss their cancelled orders"
  on public.customer_order_dismissals;
drop policy if exists "Customers hide completed orders"
  on public.customer_order_dismissals;
drop policy if exists "Customers hide their orders"
  on public.customer_order_dismissals;

create policy "Customers hide their orders"
  on public.customer_order_dismissals for insert to authenticated
  with check (
    user_id = (select auth.uid())
    and exists (
      select 1
      from public.orders o
      where o.id = order_id
        and o.customer_id = (select auth.uid())
    )
  );
