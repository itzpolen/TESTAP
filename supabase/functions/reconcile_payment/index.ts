import {
  authenticatedClient,
  corsHeaders,
  isUuid,
  jsonResponse,
  readJson,
  serviceClient,
} from "../_shared/http.ts";
import { paymongoRequest } from "../_shared/paymongo.ts";

type ProviderPayment = { id?: string; attributes?: { status?: string; amount?: number } };

function _firstPayment(value: unknown): ProviderPayment | undefined {
  if (Array.isArray(value)) return value[0] as ProviderPayment | undefined;
  const nested = (value as { data?: unknown } | null | undefined)?.data;
  return Array.isArray(nested) ? (nested[0] as ProviderPayment | undefined) : undefined;
}

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (request.method !== "POST") return jsonResponse({ error: "Method not allowed" }, 405);

  try {
    const userClient = authenticatedClient(request);
    const { data: userData, error: authError } = await userClient.auth.getUser();
    if (authError || !userData.user) return jsonResponse({ error: "Authentication is required" }, 401);
    const body = await readJson(request);
    if (!isUuid(body.payment_id)) return jsonResponse({ error: "A valid payment_id is required" }, 400);

    const { data: payment, error: paymentError } = await userClient
      .from("payments")
      .select("id, order_id, method, status, amount, provider_checkout_id, provider_payment_id")
      .eq("id", body.payment_id)
      .maybeSingle();
    if (paymentError) throw paymentError;
    if (!payment) return jsonResponse({ error: "Payment was not found or is not accessible" }, 404);
    if (payment.method !== "paymongo" || !payment.provider_checkout_id) {
      return jsonResponse({ error: "Payment has no PayMongo checkout session" }, 409);
    }
    if (payment.status === "refunded") {
      return jsonResponse({ payment_id: payment.id, status: payment.status, unchanged: true });
    }

    const isPaymentIntent = payment.provider_checkout_id.startsWith("pi_");
    const providerResponse = await paymongoRequest(
      isPaymentIntent
        ? `/payment_intents/${encodeURIComponent(payment.provider_checkout_id)}`
        : `/checkout_sessions/${encodeURIComponent(payment.provider_checkout_id)}`,
    );
    const data = providerResponse.data as {
      id?: string;
      attributes?: {
        status?: string;
        payments?: { data?: Array<{ id?: string; attributes?: { status?: string; amount?: number } }> };
      };
    } | undefined;
    let providerPayment = _firstPayment(data?.attributes?.payments);
    let providerStatus = isPaymentIntent
      ? data?.attributes?.status
      : providerPayment?.attributes?.status;
    if (!isPaymentIntent && data?.attributes?.status === "paid" &&
        providerStatus !== "paid" && providerStatus !== "succeeded" &&
        providerPayment?.id) {
      const paymentResponse = await paymongoRequest(
        `/payments/${encodeURIComponent(providerPayment.id)}`,
      );
      const paymentData = paymentResponse.data as {
        id?: string;
        attributes?: { status?: string; amount?: number };
      } | undefined;
      if (paymentData?.attributes) {
        providerPayment = {
          id: paymentData.id ?? providerPayment.id,
          attributes: paymentData.attributes,
        };
        providerStatus = paymentData.attributes.status;
      }
    }
    let status: string | null = null;
    if (providerStatus === "paid" || providerStatus === "succeeded" ||
        (!isPaymentIntent && data?.attributes?.status === "paid")) status = "paid";
    else if (providerStatus === "failed") status = "failed";
    else if (!isPaymentIntent && data?.attributes?.status === "expired") status = "cancelled";
    else if (isPaymentIntent && providerStatus === "cancelled") status = "cancelled";
    if (!status) {
      return jsonResponse({
        payment_id: payment.id,
        status: payment.status,
        provider_status: data?.attributes?.status ?? "unknown",
        pending: true,
      }, 202);
    }
    const capturedAmount = providerPayment?.attributes?.amount;
    if (status === "paid" && typeof capturedAmount !== "number") {
      throw new Error(
        "PayMongo reports a paid checkout but did not return its captured amount; payment was not reconciled.",
      );
    }

    const admin = serviceClient();
    const { data: applied, error: applyError } = await admin.rpc("apply_payment_event", {
      p_provider: "paymongo",
      p_provider_event_id: `reconcile:${payment.provider_checkout_id}:${status}`,
      p_payment_id: payment.id,
      p_event_type: `reconciliation.${status}`,
      p_payload: providerResponse,
      p_signature_valid: true,
      p_payment_status: status,
      p_amount: typeof capturedAmount === "number"
        ? capturedAmount / 100
        : null,
      p_provider_payment_id: providerPayment?.id ?? payment.provider_payment_id,
    });
    if (applyError) throw applyError;
    return jsonResponse({
      payment_id: payment.id,
      status,
      result: applied,
      late_payment_refund_required: Array.isArray(applied) &&
        applied.some((item) =>
          typeof item === "object" &&
          item !== null &&
          "refund_required" in item &&
          item.refund_required === true
        ),
    });
  } catch (error) {
    console.error("reconcile_payment:", error);
    return jsonResponse({ error: error instanceof Error ? error.message : "Payment reconciliation failed" }, 500);
  }
});
