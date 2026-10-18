import {
  authenticatedClient,
  corsHeaders,
  isUuid,
  jsonResponse,
  readJson,
  serviceClient,
} from "../_shared/http.ts";
import { amountToCentavos, paymongoRequest } from "../_shared/paymongo.ts";

function refundStatus(value: unknown): "processing" | "succeeded" | "failed" | "cancelled" {
  if (value === "succeeded") return "succeeded";
  if (value === "failed") return "failed";
  if (value === "cancelled" || value === "canceled") return "cancelled";
  return "processing";
}

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (request.method !== "POST") return jsonResponse({ error: "Method not allowed" }, 405);

  let refundQueued = false;
  try {
    const userClient = authenticatedClient(request);
    const { data: userData, error: authError } = await userClient.auth.getUser();
    if (authError || !userData.user) return jsonResponse({ error: "Authentication is required" }, 401);
    const body = await readJson(request);
    if (!isUuid(body.payment_id)
      || typeof body.amount !== "number"
      || !Number.isFinite(body.amount)
      || typeof body.reason !== "string"
      || typeof body.idempotency_key !== "string"
      || body.idempotency_key.trim().length < 8) {
      return jsonResponse({
        error: "payment_id, a positive amount, reason, and idempotency_key (at least 8 characters) are required",
      }, 400);
    }

    const { data: refundId, error: rpcError } = await userClient.rpc("request_refund", {
      p_payment_id: body.payment_id,
      p_amount: body.amount,
      p_reason: body.reason,
      p_idempotency_key: body.idempotency_key.trim(),
    });
    if (rpcError) return jsonResponse({ error: rpcError.message }, 400);
    refundQueued = true;

    const admin = serviceClient();
    const { data: refund, error: refundError } = await admin
      .from("payment_refunds")
      .select("id, payment_id, amount, status, reason, provider_refund_id, idempotency_key")
      .eq("id", refundId)
      .single();
    if (refundError) throw refundError;
    if (refund.status === "succeeded" || refund.status === "cancelled") {
      return jsonResponse({ refund_id: refund.id, status: refund.status });
    }

    const { data: payment, error: paymentError } = await admin
      .from("payments")
      .select("id, provider_payment_id, status, amount")
      .eq("id", refund.payment_id)
      .single();
    if (paymentError) throw paymentError;
    if (!payment.provider_payment_id) throw new Error("PayMongo payment ID is missing");

    const providerResponse = refund.provider_refund_id
      ? await paymongoRequest(`/refunds/${encodeURIComponent(refund.provider_refund_id)}`)
      : await paymongoRequest("/refunds", {
        method: "POST",
        idempotencyKey: `execute-refund:${refund.id}`,
        body: {
          data: {
            attributes: {
              amount: amountToCentavos(refund.amount),
              payment_id: payment.provider_payment_id,
              reason: "requested_by_customer",
              metadata: { refund_id: refund.id, reason: refund.reason },
            },
          },
        },
      });
    const providerRefund = providerResponse.data as {
      id?: string;
      attributes?: { status?: string; amount?: number };
    } | undefined;
    if (!providerRefund?.id) throw new Error("PayMongo did not return a refund ID");

    const status = refundStatus(providerRefund.attributes?.status);
    const { data: applied, error: applyError } = await admin.rpc("apply_payment_event", {
      p_provider: "paymongo",
      p_provider_event_id: `refund-response:${refund.id}:${providerRefund.id}:${status}`,
      p_payment_id: payment.id,
      p_event_type: `refund.${status}`,
      p_payload: {
        ...providerResponse,
        provider_refund_id: providerRefund.id,
      },
      p_signature_valid: true,
      p_payment_status: payment.status,
      p_amount: providerRefund.attributes?.amount == null
        ? Number(refund.amount)
        : providerRefund.attributes.amount / 100,
      p_provider_payment_id: payment.provider_payment_id,
      p_refund_id: refund.id,
      p_refund_status: status,
    });
    if (applyError) throw applyError;

    return jsonResponse({ refund_id: refund.id, provider_refund_id: providerRefund.id, status, result: applied });
  } catch (error) {
    console.error("request_refund:", error);
    return jsonResponse({
      error: error instanceof Error ? error.message : "Refund request failed",
      refund_may_be_queued: refundQueued,
    }, refundQueued ? 502 : 500);
  }
});
