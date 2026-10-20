import {
  corsHeaders,
  jsonResponse,
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

  const expectedSecret = Deno.env.get("AQUADIRECT_PAYMENT_WORKER_SECRET");
  if (!expectedSecret) return jsonResponse({ error: "Payment worker secret is not configured" }, 500);
  if (request.headers.get("x-worker-secret") !== expectedSecret) {
    return jsonResponse({ error: "Unauthorized" }, 401);
  }

  const admin = serviceClient();
  const { data: actions, error: claimError } = await admin.rpc(
    "claim_payment_provider_actions",
    { p_limit: 20 },
  );
  if (claimError) {
    console.error("process_payment_provider_actions claim:", claimError);
    return jsonResponse({ error: claimError.message }, 500);
  }

  const results: Array<{ action_id: string; status: string; error?: string }> = [];
  for (const action of actions ?? []) {
    try {
      const payload = action.payload as Record<string, unknown>;
      if (action.action_type === "expire_checkout") {
        const checkoutId = payload.provider_checkout_id;
        if (typeof checkoutId !== "string" || !checkoutId) {
          throw new Error("PayMongo checkout ID is missing from the queued action");
        }
        const { data: payment, error: paymentError } = await admin
          .from("payments")
          .select("status")
          .eq("id", action.payment_id)
          .single();
        if (paymentError) throw paymentError;
        if (!["paid", "partially_refunded", "refunded"].includes(payment.status)) {
          if (checkoutId.startsWith("pi_")) {
            const intentResponse = await paymongoRequest(
              `/payment_intents/${encodeURIComponent(checkoutId)}`,
            );
            const intent = intentResponse.data as {
              attributes?: { status?: string };
            } | undefined;
            if (!["succeeded", "cancelled"].includes(intent?.attributes?.status ?? "")) {
              await paymongoRequest(
                `/payment_intents/${encodeURIComponent(checkoutId)}/cancel`,
                { method: "POST", idempotencyKey: action.idempotency_key },
              );
            }
          } else {
            const sessionResponse = await paymongoRequest(
              `/checkout_sessions/${encodeURIComponent(checkoutId)}`,
            );
            const session = sessionResponse.data as {
              attributes?: { status?: string };
            } | undefined;
            if (session?.attributes?.status !== "expired") {
              await paymongoRequest(
                `/checkout_sessions/${encodeURIComponent(checkoutId)}/expire`,
                { method: "POST", body: { data: { attributes: {} } }, idempotencyKey: action.idempotency_key },
              );
            }
          }
        }
      } else if (action.action_type === "refund") {
        const paymentId = payload.provider_payment_id;
        const amount = payload.amount;
        if (typeof paymentId !== "string" || !paymentId || amount == null) {
          throw new Error("PayMongo payment ID or refund amount is missing from the queued action");
        }
        const response = await paymongoRequest("/refunds", {
          method: "POST",
          idempotencyKey: action.idempotency_key,
          body: {
            data: {
              attributes: {
                amount: amountToCentavos(amount),
                payment_id: paymentId,
                reason: "requested_by_customer",
                metadata: { refund_id: action.refund_id, reason: payload.reason },
              },
            },
          },
        });
        const refund = response.data as {
          id?: string;
          attributes?: { status?: string; amount?: number };
        } | undefined;
        if (!refund?.id || !action.refund_id) throw new Error("PayMongo refund response is incomplete");

        const { data: payment, error: paymentError } = await admin
          .from("payments")
          .select("status, provider_payment_id")
          .eq("id", action.payment_id)
          .single();
        if (paymentError) throw paymentError;
        const { error: applyError } = await admin.rpc("apply_payment_event", {
          p_provider: "paymongo",
          p_provider_event_id: `outbox:${action.action_id}:${refund.id}`,
          p_payment_id: action.payment_id,
          p_event_type: `refund.${refundStatus(refund.attributes?.status)}`,
          p_payload: { ...response, provider_refund_id: refund.id },
          p_signature_valid: true,
          p_payment_status: payment.status,
          p_amount: refund.attributes?.amount == null
            ? Number(amount)
            : refund.attributes.amount / 100,
          p_provider_payment_id: payment.provider_payment_id,
          p_refund_id: action.refund_id,
          p_refund_status: refundStatus(refund.attributes?.status),
        });
        if (applyError) throw applyError;
      } else {
        throw new Error(`Unsupported payment provider action: ${action.action_type}`);
      }

      const { error: completeError } = await admin.rpc("complete_payment_provider_action", {
        p_action_id: action.action_id,
        p_success: true,
        p_error: null,
      });
      if (completeError) throw completeError;
      results.push({ action_id: action.action_id, status: "completed" });
    } catch (error) {
      const message = error instanceof Error ? error.message : "Provider action failed";
      console.error("process_payment_provider_actions action:", action.action_id, error);
      const { error: completeError } = await admin.rpc("complete_payment_provider_action", {
        p_action_id: action.action_id,
        p_success: false,
        p_error: message,
      });
      if (completeError) console.error("process_payment_provider_actions retry scheduling:", completeError);
      results.push({ action_id: action.action_id, status: "failed", error: message });
    }
  }
  return jsonResponse({ processed: results.length, results });
});
