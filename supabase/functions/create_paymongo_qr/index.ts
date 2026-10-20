import {
  authenticatedClient,
  corsHeaders,
  isUuid,
  jsonResponse,
  readJson,
  serviceClient,
} from "../_shared/http.ts";
import { amountToCentavos, paymongoRequest } from "../_shared/paymongo.ts";

type PaymentIntent = {
  id?: string;
  attributes?: {
    status?: string;
    next_action?: {
      code?: { image_url?: string };
    };
  };
};

function qrImage(intent: PaymentIntent): string | null {
  const image = intent.attributes?.next_action?.code?.image_url;
  return typeof image === "string" && image.length > 0 ? image : null;
}

async function attachQrPaymentMethod(
  intentId: string,
  paymentId: string,
  expiresAt: string,
): Promise<PaymentIntent> {
  const remainingSeconds = Math.floor((Date.parse(expiresAt) - Date.now()) / 1000);
  if (remainingSeconds < 60) {
    throw new Error("This order is too close to its checkout deadline for a new QR code");
  }
  const expirySeconds = Math.min(remainingSeconds, 9000);
  const method = await paymongoRequest("/payment_methods", {
    method: "POST",
    idempotencyKey: `qrph-method:${paymentId}:${crypto.randomUUID()}`,
    body: {
      data: {
        attributes: {
          type: "qrph",
          expiry_seconds: expirySeconds,
        },
      },
    },
  });
  const methodId = (method.data as { id?: string } | undefined)?.id;
  if (!methodId) throw new Error("PayMongo did not return a QRPH payment method");

  const response = await paymongoRequest(
    `/payment_intents/${encodeURIComponent(intentId)}/attach`,
    {
      method: "POST",
      idempotencyKey: `qrph-attach:${paymentId}:${methodId}`,
      body: { data: { attributes: { payment_method: methodId } } },
    },
  );
  return response.data as PaymentIntent;
}

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (request.method !== "POST") return jsonResponse({ error: "Method not allowed" }, 405);

  try {
    const userClient = authenticatedClient(request);
    const { data: userData, error: authError } = await userClient.auth.getUser();
    if (authError || !userData.user) {
      return jsonResponse({ error: "Authentication is required" }, 401);
    }

    const body = await readJson(request);
    if (!isUuid(body.order_id)) return jsonResponse({ error: "A valid order_id is required" }, 400);

    const admin = serviceClient();
    const { data: order, error: orderError } = await admin
      .from("orders")
      .select("id, customer_id, status, total, checkout_expires_at")
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

    let intentId = payment.provider_checkout_id;
    let intent: PaymentIntent;
    if (intentId) {
      if (!intentId.startsWith("pi_")) {
        return jsonResponse({
          error: "This payment already has a hosted checkout. Start a new order to pay by QRPH.",
        }, 409);
      }
      const current = await paymongoRequest(
        `/payment_intents/${encodeURIComponent(intentId)}`,
      );
      intent = current.data as PaymentIntent;
      const status = intent.attributes?.status;
      if (status === "succeeded") {
        return jsonResponse({ payment_intent_id: intentId, paid: true });
      }
      if (status === "cancelled") {
        return jsonResponse({ error: "This QR payment was cancelled" }, 409);
      }
      if (status === "awaiting_payment_method") {
        intent = await attachQrPaymentMethod(intentId, payment.id, order.checkout_expires_at);
      }
    } else {
      const created = await paymongoRequest("/payment_intents", {
        method: "POST",
        idempotencyKey: `qrph-intent:${payment.id}`,
        body: {
          data: {
            attributes: {
              amount: amountToCentavos(payment.amount),
              currency: payment.currency,
              payment_method_allowed: ["qrph"],
              description: `AquaDirect order ${order.id}`,
              metadata: { order_id: order.id, payment_id: payment.id },
            },
          },
        },
      });
      intent = created.data as PaymentIntent;
      if (!intent.id) throw new Error("PayMongo did not return a payment intent ID");
      intentId = intent.id;

      const { error: saveError } = await admin.rpc("record_paymongo_checkout", {
        p_payment_id: payment.id,
        p_checkout_id: intentId,
      });
      if (saveError) throw saveError;

      intent = await attachQrPaymentMethod(intentId, payment.id, order.checkout_expires_at);
    }

    const imageUrl = qrImage(intent);
    if (!intentId || !imageUrl) {
      throw new Error("PayMongo did not return the QRPH image for this payment");
    }
    return jsonResponse({
      payment_intent_id: intentId,
      qr_image_url: imageUrl,
      expires_at: order.checkout_expires_at,
    });
  } catch (error) {
    console.error("create_paymongo_qr:", error);
    return jsonResponse({
      error: error instanceof Error ? error.message : "QRPH payment creation failed",
    }, 500);
  }
});
