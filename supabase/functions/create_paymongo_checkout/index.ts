import {
  authenticatedClient,
  corsHeaders,
  isUuid,
  jsonResponse,
  readJson,
  serviceClient,
} from "../_shared/http.ts";
import { amountToCentavos, paymongoRequest } from "../_shared/paymongo.ts";

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (request.method !== "POST") return jsonResponse({ error: "Method not allowed" }, 405);

  try {
    const userClient = authenticatedClient(request);
    const { data: userData, error: authError } = await userClient.auth.getUser();
    if (authError || !userData.user) return jsonResponse({ error: "Authentication is required" }, 401);

    const body = await readJson(request);
    if (!isUuid(body.order_id)) return jsonResponse({ error: "A valid order_id is required" }, 400);
    const admin = serviceClient();

    const { data: order, error: orderError } = await admin
      .from("orders")
      .select("id, customer_id, status, checkout_expires_at")
      .eq("id", body.order_id)
      .eq("customer_id", userData.user.id)
      .maybeSingle();
    if (orderError) throw orderError;
    if (!order) return jsonResponse({ error: "Order was not found" }, 404);
    if (order.status !== "pending"
      || !order.checkout_expires_at
      || Date.parse(order.checkout_expires_at) <= Date.now()) {
      return jsonResponse({ error: "This order is no longer available for payment" }, 409);
    }

    const { data: payments, error: paymentError } = await admin
      .from("payments")
      .select("id, method, status, amount, currency, provider_checkout_id, idempotency_key")
      .eq("order_id", order.id)
      .eq("customer_id", userData.user.id)
      .in("status", ["pending", "processing"])
      .order("attempt_number", { ascending: false })
      .limit(1);
    if (paymentError) throw paymentError;
    const payment = payments?.[0];
    if (!payment || payment.method !== "paymongo") {
      return jsonResponse({ error: "No payable PayMongo attempt was found" }, 409);
    }

    let session: Record<string, unknown>;
    if (payment.provider_checkout_id) {
      if (payment.provider_checkout_id.startsWith("pi_")) {
        return jsonResponse({
          error: "This payment uses an in-app QR code. Resume it from the QR payment screen.",
        }, 409);
      }
      session = await paymongoRequest(`/checkout_sessions/${encodeURIComponent(payment.provider_checkout_id)}`);
    } else {
      const successUrl = Deno.env.get("PAYMONGO_SUCCESS_URL");
      const cancelUrl = Deno.env.get("PAYMONGO_CANCEL_URL");
      if (!successUrl || !cancelUrl) {
        throw new Error("PAYMONGO_SUCCESS_URL and PAYMONGO_CANCEL_URL are required");
      }
      const successReturnUrl = new URL(successUrl);
      successReturnUrl.searchParams.set("order_id", order.id);
      const cancelReturnUrl = new URL(cancelUrl);
      cancelReturnUrl.searchParams.set("order_id", order.id);
      session = await paymongoRequest("/checkout_sessions", {
        method: "POST",
        idempotencyKey: `checkout:${payment.idempotency_key}`,
        body: {
          data: {
            attributes: {
              line_items: [{
                currency: payment.currency,
                amount: amountToCentavos(payment.amount),
                name: `AquaDirect order ${order.id}`,
                quantity: 1,
              }],
              payment_method_types: ["gcash", "paymaya", "qrph", "card"],
              description: `AquaDirect order ${order.id}`,
              success_url: successReturnUrl.toString(),
              cancel_url: cancelReturnUrl.toString(),
              expires_at: Math.floor(Date.parse(order.checkout_expires_at) / 1000),
              metadata: { order_id: order.id, payment_id: payment.id },
            },
          },
        },
      });
    }

    const sessionData = session.data as {
      id?: string;
      attributes?: { checkout_url?: string; status?: string };
    } | undefined;
    const checkoutId = sessionData?.id;
    const checkoutUrl = sessionData?.attributes?.checkout_url;
    if (!checkoutId || !checkoutUrl || sessionData?.attributes?.status === "expired") {
      return jsonResponse({ error: "PayMongo did not return an active checkout session" }, 502);
    }
    const { error: saveError } = await admin.rpc("record_paymongo_checkout", {
      p_payment_id: payment.id,
      p_checkout_id: checkoutId,
    });
    if (saveError) throw saveError;

    return jsonResponse({
      order_id: order.id,
      payment_id: payment.id,
      checkout_session_id: checkoutId,
      checkout_url: checkoutUrl,
      expires_at: order.checkout_expires_at,
    });
  } catch (error) {
    console.error("create_paymongo_checkout:", error);
    return jsonResponse({ error: error instanceof Error ? error.message : "Checkout creation failed" }, 500);
  }
});
