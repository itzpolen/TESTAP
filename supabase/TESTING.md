# AquaDirect Supabase deployment and testing checklist

## Before applying the schema

- Use a fresh Supabase project and back up any existing data.
- Confirm `postgis`, `pg_trgm`, and `pg_cron` are available for the project. If `pg_cron` is unavailable, configure a trusted scheduled Edge Function to call the expiry RPCs instead.
- Apply `schema.sql` and verify the `aquadirect-expire-paymongo-orders` cron job exists in `cron.job`.
- The `security_barrier` options on the public/read-filtered views are intentional; the corresponding Supabase linter warning is expected and should not be removed without replacing the view security boundary.
- Create five confirmed local Auth users before applying `seed.sql`: one admin, two station owners, one customer, and one rider. The seed is development-only; never use the sample accounts or records in production.

## Edge Function configuration

Deploy `create_paymongo_checkout`, `paymongo_webhook`, `reconcile_payment`, `request_refund`, `set_customer_status`, `process_payment_provider_actions`, and `payment_return`.
Customer suspension/reactivation must go through the `set_customer_status` Edge Function; the underlying SQL RPC is service-role-only so profile status cannot be changed without the Auth ban synchronization workflow.

Set these secrets in the Supabase Edge Function environment:

- `paymongotestmodekys`
- `PAYMONGO_WEBHOOK_SECRET`
- `PAYMONGO_SUCCESS_URL`
- `PAYMONGO_CANCEL_URL`
- `AQUADIRECT_PAYMENT_WORKER_SECRET`

`SUPABASE_URL`, `SUPABASE_ANON_KEY`, and `SUPABASE_SERVICE_ROLE_KEY` are supplied by Supabase. Keep the service-role key, PayMongo keys, and worker secret server-side only.

For a local Supabase CLI workflow, deploy the checkout function with
`supabase functions deploy create_paymongo_checkout`, then add the PayMongo
test secret and HTTPS success/cancel URLs under the project's Edge Function
secrets. Switch to live credentials only after completing the payment and
webhook checks below. Do not add `paymongotestmodekys` to the Flutter `.env`.
The customer Flutter app creates orders through the authenticated `create_order`
RPC and starts online payment by invoking `create_paymongo_checkout` with the
returned order ID. Deploy the function before testing the PayMongo choice; no
PayMongo credential belongs in Flutter's `.env` or a client build.

When deploying payment flow updates, deploy each changed function:
`supabase functions deploy create_paymongo_checkout`,
`supabase functions deploy paymongo_webhook`, and
`supabase functions deploy reconcile_payment`.

For GitHub Pages, set the repository's Pages source to **GitHub Actions** and
add `SUPABASE_URL` and `SUPABASE_ANON_KEY` as repository Actions secrets. The
`Deploy Flutter web app to GitHub Pages` workflow publishes the Flutter app
from `build/web` and copies the root `index.html` payment-return screen to
`payment-return.html`. The root file is a payment callback page, not the Flutter
app homepage.

Set the PayMongo redirect secrets to that separate return page, with a
different status query value:

```text
PAYMONGO_SUCCESS_URL=https://<owner>.github.io/<repository>/payment-return.html?status=success
PAYMONGO_CANCEL_URL=https://<owner>.github.io/<repository>/payment-return.html?status=cancel
```

Replace `<owner>` and `<repository>` with the actual GitHub Pages URL. For a
user/organization site or custom domain, adjust the path to match that site's
URL. The return page tells customers to go back to the app; it does not claim
payment succeeded. The PayMongo webhook, not the redirect, is authoritative
for payment status. Test with PayMongo test credentials and confirm the signed
webhook updates the `payments` row before enabling live keys.

Configure a trusted scheduler to POST `{}` to `process_payment_provider_actions` at least once per minute with the `x-worker-secret` header set to `AQUADIRECT_PAYMENT_WORKER_SECRET`. The schema's `pg_cron` job expires pending PayMongo and unaccepted COD orders; the Edge Function worker processes the resulting PayMongo checkout-expiry and refund outbox actions.

Configure the PayMongo webhook URL as:

`https://<project-ref>.supabase.co/functions/v1/paymongo_webhook`

Subscribe to payment paid/failed, checkout expired/payment, and refund lifecycle events supported by the PayMongo account. Do not disable signature verification.

## Database and access checks

- [ ] Anonymous users can read published station discovery data, but `public_stations` contains neither station email nor phone.
- [ ] Anonymous users only see reviews for visible reviews at currently published, active, verified stations.
- [ ] Customer, station, rider, support, finance, and verifier roles can read only the rows allowed by their RLS policies.
- [ ] A customer cannot create support tickets for another customer's order or set status/assignee fields.
- [ ] Station staff cannot change stock directly; inventory changes produce ledger entries.
- [ ] Audit log rows cannot be updated or deleted.
- [ ] Customer suspension updates both `profiles.status` and the corresponding Supabase Auth ban; reactivation removes the ban.

## Discovery and checkout checks

- [ ] Nearby-station search returns stable pages ordered by distance and station ID, respects the 1–100 page-size bound, and filters by radius and open status.
- [ ] A delivery zone matches by PSGC codes when both address and zone have codes; legacy text matching remains available where codes are absent.
- [ ] An overnight schedule such as 22:00–02:00 is open at 23:00 and 01:00 on the next weekday, but closed at 02:00.
- [ ] A customer cannot create an order while a station is closed, unpublished, suspended, or outside its delivery coverage.
- [ ] New-gallon orders include the container charge and applicable deposit; refill orders do not include a deposit.
- [ ] Order totals satisfy `total = subtotal + container_total + deposit_total + delivery_fee - discount_total`.
- [ ] Reusing an idempotency key with the same payload returns the same order; changing any payload field is rejected.
- [ ] Replaying checkout with a converted cart returns its existing order; a mismatched cart payload is rejected.
- [ ] Active stock and per-customer quantity caps reject excess reservations, and every cancellation/expiry releases stock exactly once.
- [ ] A COD order awaiting station acceptance expires after its acceptance timeout.

## Payment and delivery checks

- [ ] PayMongo checkout creation is allowed only for the signed-in order owner and returns a session expiring no later than the database checkout deadline.
- [ ] A valid PayMongo paid webhook marks the payment paid once; replaying the same event is deduplicated.
- [ ] A verified paid webhook updates the order row; an open seller portal refreshes the payment badge in real time to “Payment received” and enables order confirmation.
- [ ] The PayMongo success URL includes the order ID; tapping Return clears checkout from the app navigation stack, opens Home, and invokes `reconcile_payment` so a missed/late webhook is reconciled.
- [ ] Invalid signatures are rejected. A stale, expired, or mismatched payment is recorded and routed to the automatic-refund workflow rather than fulfilling an order.
- [ ] The customer return page can observe payment updates through Realtime on `payments`, with reconciliation as a fallback.
- [ ] The cron expiry routine cancels unpaid orders, releases reserved inventory, and queues checkout expiry; the scheduled worker expires the PayMongo session.
- [ ] Finance/admin refund requests are idempotent, respect the remaining refundable balance, and reconcile succeeded/failed provider responses.
- [ ] Delivery assignment is restricted to the assigned rider and station workflows; rider location updates appear in customer tracking only for that customer's order.
- [ ] A rider can upload proof under the order ID and link it to the matching delivery.

## End-to-end flows

- [ ] Station owner application: upload every required document, reject/replace a document, resubmit, approve, add catalog/hours/zones, publish, pause, resume, suspend/reinstate, and archive.
- [ ] Customer order: search stations, select refill/new gallon, choose COD or PayMongo, follow status/tracking, cancel within allowed states, and review after delivery.
- [ ] A customer can remove a cancelled order from their own order history; the order and payment records remain available to the station and support.
- [ ] Station portal: accept/decline orders, update preparation/delivery status, assign/fix rider details, collect COD, manage inventory, disable staff, and reply to reviews.
- [ ] Support can inspect permitted customer/order details without exposing payment credentials or unrelated records.
- [ ] Device registration transfers a push token when the same device signs into a different customer account.

These checks are a release checklist, not evidence of a completed live Supabase or PayMongo integration test. Run them in a disposable Supabase project with PayMongo test credentials before production.
