/// <reference lib="deno.ns" />

import { corsHeaders, isUuid, jsonResponse, serviceClient } from "../_shared/http.ts";
import { paymongoRequest } from "../_shared/paymongo.ts";

function equalHex(left: string, right: string): boolean {
  if (!/^[0-9a-f]+$/i.test(left) || !/^[0-9a-f]+$/i.test(right) || left.length !== right.length) {
    return false;
  }
  let difference = 0;
  for (let index = 0; index < left.length; index++) {
    difference |= left.charCodeAt(index) ^ right.charCodeAt(index);
  }
  return difference === 0;
}

async function verifySignature(rawBody: string, header: string, liveMode: boolean): Promise<boolean> {
  const secret = Deno.env.get("PAYMONGO_WEBHOOK_SECRET");
  if (!secret) throw new Error("PAYMONGO_WEBHOOK_SECRET is required");
  const values = Object.fromEntries(
    header.split(",").map((part) => part.trim().split("=", 2) as [string, string]),
  );
  if (!values.t || !/^\d+$/.test(values.t)
    || Math.abs(Date.now() / 1000 - Number(values.t)) > 300) return false;
  const expected = liveMode ? values.li : values.te;
  if (!expected) return false;
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const signature = await crypto.subtle.sign(
    "HMAC",
    key,
    new TextEncoder().encode(`${values.t}.${rawBody}`),
  );
  const actual = Array.from(new Uint8Array(signature), (byte) => byte.toString(16).padStart(2, "0")).join("");
  return equalHex(actual, expected);
}
function paymentStatus(eventType: string): string | null {
  if (eventType === "payment.paid" || eventType === "checkout_session.payment.paid" ||
    eventType === "qr.paid" || eventType === "qrph.paid") return "paid";
  if (eventType === "payment.failed" || eventType === "checkout_session.payment.failed") return "failed";
  if (eventType === "checkout_session.expired") return "cancelled";
  return null;
}

type ProviderPayment = { id?: string; attributes?: { status?: string; amount?: number } };

function _firstPayment(value: unknown): ProviderPayment | undefined {
  if (Array.isArray(value)) return value[0] as ProviderPayment | undefined;
  const nested = (value as { data?: unknown } | null | undefined)?.data;
  return Array.isArray(nested) ? (nested[0] as ProviderPayment | undefined) : undefined;
}


function refundStatus(value: unknown): "processing" | "succeeded" | "failed" | "cancelled" | null {
  if (typeof value !== "string") return null;
  if (value.endsWith(".succeeded") || value === "succeeded") return "succeeded";
  if (value.endsWith(".failed") || value === "failed") return "failed";
  if (value.endsWith(".cancelled") || value.endsWith(".canceled")
    || value === "cancelled" || value === "canceled") return "cancelled";
  if (value.endsWith(".processing") || value.endsWith(".pending")
    || value === "processing" || value === "pending") return "processing";
  return null;
}

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (request.method !== "POST") return jsonResponse({ error: "Method not allowed" }, 405);

  try {
    const rawBody = await request.text();
    let event: {
      data?: {
        id?: string;
        attributes?: {
          type?: string;
          livemode?: boolean;
          data?: {
            id?: string;
            type?: string;
            attributes?: Record<string, unknown>;
          };
        };
      };
    };
    try {
      event = JSON.parse(rawBody);
    } catch {
      return jsonResponse({ error: "Webhook body must be valid JSON" }, 400);
    }
    const eventId = event.data?.id;
    const eventType = event.data?.attributes?.type;
    if (!eventId || !eventType) return jsonResponse({ error: "Webhook event ID and type are required" }, 400);

    const signature = request.headers.get("paymongo-signature");
    if (!signature || !await verifySignature(
      rawBody,
      signature,
      event.data?.attributes?.livemode === true,
    )) {
      return jsonResponse({ error: "Invalid PayMongo webhook signature" }, 401);
    }

    const resource = event.data?.attributes?.data;
    const attributes = resource?.attributes ?? {};
    const metadata = attributes.metadata as Record<string, unknown> | undefined;
    const isQrPaid = eventType === "qr.paid" || eventType === "qrph.paid";
    const isQrExpired = eventType === "qr.expired" || eventType === "qrph.expired";
    const paymentIntentValue = attributes.payment_intent_id ?? attributes.payment_intent;
    const paymentIntentId = typeof paymentIntentValue === "string"
      ? paymentIntentValue
      : typeof paymentIntentValue === "object" && paymentIntentValue !== null &&
          "id" in paymentIntentValue && typeof paymentIntentValue.id === "string"
      ? paymentIntentValue.id
      : typeof resource?.id === "string" && resource.id.startsWith("pi_")
      ? resource.id
      : null;
    const nestedFirst = _firstPayment(attributes.payments);
    const paymentIdFromMetadata = metadata?.payment_id;
    const paymentIdFromPayload = isUuid(paymentIdFromMetadata) ? paymentIdFromMetadata : null;
    const checkoutId = eventType.startsWith("checkout_session.")
      ? resource?.id
      : typeof attributes.checkout_session_id === "string"
      ? attributes.checkout_session_id
      : null;
    let providerPaymentId = resource?.type === "payment"
      ? resource.id
      : nestedFirst?.id ?? (isQrPaid || isQrExpired ? null : paymentIntentId);

    const admin = serviceClient();
    let payment: {
      id: string;
      status: string;
      amount: number;
      provider_checkout_id: string | null;
      provider_payment_id: string | null;
    } | null = null;
    if (paymentIdFromPayload) {
      const result = await admin.from("payments")
        .select("id, status, amount, provider_checkout_id, provider_payment_id")
        .eq("id", paymentIdFromPayload)
        .maybeSingle();
      if (result.error) throw result.error;
      payment = result.data;
    }
    if (!payment && checkoutId) {
      const result = await admin.from("payments")
        .select("id, status, amount, provider_checkout_id, provider_payment_id")
        .eq("provider_checkout_id", checkoutId)
        .maybeSingle();
      if (result.error) throw result.error;
      payment = result.data;
    }
    if (!payment && paymentIntentId) {
      const result = await admin.from("payments")
        .select("id, status, amount, provider_checkout_id, provider_payment_id")
        .eq("provider_checkout_id", paymentIntentId)
        .maybeSingle();
      if (result.error) throw result.error;
      payment = result.data;
    }
    if (!payment && providerPaymentId) {
      const result = await admin.from("payments")
        .select("id, status, amount, provider_checkout_id, provider_payment_id")
        .eq("provider_payment_id", providerPaymentId)
        .maybeSingle();
      if (result.error) throw result.error;
      payment = result.data;
    }

    let qrIntentPayment: ProviderPayment | undefined;
    if (isQrPaid) {
      if (!paymentIntentId) {
        throw new Error("PayMongo QR paid event did not include its payment intent ID");
      }
      const intentResponse = await paymongoRequest(
        `/payment_intents/${encodeURIComponent(paymentIntentId)}`,
      );
      const intent = intentResponse.data as {
        attributes?: {
          status?: string;
          payments?: { data?: Array<{ id?: string; attributes?: { status?: string; amount?: number } }> };
        };
      } | undefined;
      if (intent?.attributes?.status !== "succeeded") {
        throw new Error("PayMongo QR paid event is not confirmed by the payment intent");
      }
      qrIntentPayment = _firstPayment(intent.attributes.payments);
      if (!qrIntentPayment?.id || typeof qrIntentPayment.attributes?.amount !== "number") {
        throw new Error("PayMongo did not return the captured QR payment details");
      }
      providerPaymentId = qrIntentPayment.id;
    }

    const normalizedStatus = paymentStatus(eventType);
    const refundId = typeof attributes.refund_id === "string"
      ? attributes.refund_id
      : typeof metadata?.refund_id === "string"
      ? metadata.refund_id
      : resource?.type === "refund" ? resource.id : null;
    let refund: { id: string; status: string; payment_id: string } | null = null;
    if (refundId) {
      const refundQuery = admin.from("payment_refunds")
        .select("id, status, payment_id")
        .eq(
          isUuid(metadata?.refund_id) ? "id" : "provider_refund_id",
          isUuid(metadata?.refund_id) ? metadata.refund_id : refundId,
        );
      const result = await refundQuery.maybeSingle();
      if (result.error) throw result.error;
      refund = result.data;
    }

    const rawAmount = qrIntentPayment?.attributes?.amount ??
      (typeof attributes.amount === "number" ? attributes.amount : nestedFirst?.attributes?.amount);
    const amount = typeof rawAmount === "number" ? rawAmount / 100 : null;
    const normalizedRefundStatus = refundStatus(eventType) ??
      refundStatus(attributes.status);
    const { data: result, error } = await admin.rpc("apply_payment_event", {
      p_provider: "paymongo",
      p_provider_event_id: eventId,
      p_payment_id: refund?.payment_id ?? payment?.id ?? null,
      p_event_type: eventType,
      p_payload: event,
      p_signature_valid: true,
      p_payment_status: isQrExpired ? "processing" : normalizedStatus ?? payment?.status ?? null,
      p_amount: amount,
      p_provider_payment_id: providerPaymentId,
      p_refund_id: refund?.id ?? null,
      p_refund_status: refundId ? normalizedRefundStatus : null,
    });
    if (error) throw error;
    return jsonResponse({ received: true, result });
  } catch (error) {
    console.error("paymongo_webhook:", error);
    return jsonResponse({ error: error instanceof Error ? error.message : "Webhook processing failed" }, 500);
  }
});
