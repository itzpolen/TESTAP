export async function paymongoRequest(
  path: string,
  options: { method?: string; body?: unknown; idempotencyKey?: string } = {},
) {
  const secret = Deno.env.get("PAYMONGO_KEY");
  if (!secret) throw new Error("PAYMONGO_KEY is required");

  const headers: Record<string, string> = {
    Authorization: `Basic ${btoa(`${secret}:`)}`,
    "Content-Type": "application/json",
  };
  if (options.idempotencyKey) headers["Idempotency-Key"] = options.idempotencyKey;

  const response = await fetch(`https://api.paymongo.com/v1${path}`, {
    method: options.method ?? "GET",
    headers,
    body: options.body === undefined ? undefined : JSON.stringify(options.body),
  });
  const text = await response.text();
  let payload: Record<string, unknown> = {};
  if (text) {
    try {
      payload = JSON.parse(text);
    } catch {
      throw new Error(`PayMongo returned a non-JSON response (${response.status})`);
    }
  }
  if (!response.ok) {
    const errors = Array.isArray(payload.errors) ? payload.errors : [];
    const detail = errors.map((item) => {
      const error = item as { detail?: string; code?: string };
      return error.detail ?? error.code ?? "PayMongo request failed";
    }).join("; ");
    throw new Error(detail || `PayMongo request failed (${response.status})`);
  }
  return payload;
}

export function amountToCentavos(amount: unknown): number {
  const numericAmount = typeof amount === "number" ? amount : Number(amount);
  const centavos = Math.round(numericAmount * 100);
  if (!Number.isFinite(numericAmount) || !Number.isSafeInteger(centavos) || centavos <= 0) {
    throw new Error("Payment amount is invalid");
  }
  return centavos;
}
