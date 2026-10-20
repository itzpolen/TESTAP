create or replace function public.confirm_paid_paymongo_order()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  previous_order_transition text := current_setting('app.order_transition', true);
  previous_order_transition_note text := current_setting('app.order_transition_note', true);
begin
  if new.method <> 'paymongo' or new.status <> 'paid' then
    return new;
  end if;

  perform set_config('app.order_transition', 'on', true);
  perform set_config(
    'app.order_transition_note',
    'PayMongo payment received; order automatically confirmed',
    true
  );
  update public.orders
  set status = 'confirmed',
      accepted_at = coalesce(accepted_at, now()),
      acceptance_expires_at = null
  where id = new.order_id
    and payment_method = 'paymongo'
    and status = 'pending';
  perform set_config(
    'app.order_transition',
    coalesce(previous_order_transition, ''),
    true
  );
  perform set_config(
    'app.order_transition_note',
    coalesce(previous_order_transition_note, ''),
    true
  );
  return new;
end;
$$;

revoke all on function public.confirm_paid_paymongo_order()
  from public, anon, authenticated;

drop trigger if exists confirm_paid_paymongo_order on public.payments;
create trigger confirm_paid_paymongo_order
  after update of status on public.payments
  for each row
  when (
    old.status is distinct from new.status
    and new.status = 'paid'
    and new.method = 'paymongo'
  )
  execute function public.confirm_paid_paymongo_order();

do $$
begin
  perform set_config('app.order_transition', 'on', true);
  perform set_config(
    'app.order_transition_note',
    'PayMongo payment received; order automatically confirmed',
    true
  );
  update public.orders o
  set status = 'confirmed',
      accepted_at = coalesce(o.accepted_at, now()),
      acceptance_expires_at = null
  where o.payment_method = 'paymongo'
    and o.status = 'pending'
    and exists (
      select 1
      from public.payments p
      where p.order_id = o.id
        and p.method = 'paymongo'
        and p.status = 'paid'
    );
  perform set_config('app.order_transition', '', true);
  perform set_config('app.order_transition_note', '', true);
end;
$$;
