create table if not exists public.customer_order_dismissals (
  user_id uuid not null references public.profiles(id) on delete cascade,
  order_id uuid not null references public.orders(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, order_id)
);

alter table public.customer_order_dismissals enable row level security;

drop policy if exists "Customers view their order dismissals"
  on public.customer_order_dismissals;
create policy "Customers view their order dismissals"
  on public.customer_order_dismissals for select to authenticated
  using (user_id = (select auth.uid()));

drop policy if exists "Customers dismiss their cancelled orders"
  on public.customer_order_dismissals;
create policy "Customers dismiss their cancelled orders"
  on public.customer_order_dismissals for insert to authenticated
  with check (
    user_id = (select auth.uid())
    and exists (
      select 1
      from public.orders o
      where o.id = order_id
        and o.customer_id = (select auth.uid())
        and o.status = 'cancelled'
    )
  );

grant select, insert on public.customer_order_dismissals to authenticated;
