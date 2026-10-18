import {
  authenticatedClient,
  corsHeaders,
  isUuid,
  jsonResponse,
  readJson,
  serviceClient,
} from "../_shared/http.ts";

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (request.method !== "POST") return jsonResponse({ error: "Method not allowed" }, 405);

  try {
    const userClient = authenticatedClient(request);
    const { data: userData, error: authError } = await userClient.auth.getUser();
    if (authError || !userData.user) return jsonResponse({ error: "Authentication is required" }, 401);
    const body = await readJson(request);
    if (!isUuid(body.user_id)
      || (body.status !== "active" && body.status !== "suspended")
      || (body.reason !== undefined && typeof body.reason !== "string")) {
      return jsonResponse({ error: "user_id, a valid status, and optional reason are required" }, 400);
    }

    const { data: permitted, error: permissionError } = await userClient.rpc("has_permission", {
      required_permission: "customer.suspend",
    });
    if (permissionError) throw permissionError;
    if (!permitted) return jsonResponse({ error: "Customer management permission is required" }, 403);

    const admin = serviceClient();
    const { error: statusError } = await admin.rpc("set_customer_status", {
      p_user_id: body.user_id,
      p_status: body.status,
      p_reason: body.reason ?? null,
      p_actor_id: userData.user.id,
    });
    if (statusError) throw statusError;

    const { error: authUpdateError } = await admin.auth.admin.updateUserById(body.user_id, {
      ban_duration: body.status === "suspended" ? "876000h" : "none",
    });
    if (authUpdateError) {
      console.error("set_customer_status Auth update:", authUpdateError);
      return jsonResponse({
        error: `Profile status was updated, but the Auth ban could not be synchronized: ${authUpdateError.message}`,
        profile_status_updated: true,
        auth_ban_updated: false,
      }, 502);
    }

    return jsonResponse({ user_id: body.user_id, status: body.status, auth_ban_updated: true });
  } catch (error) {
    console.error("set_customer_status:", error);
    return jsonResponse({ error: error instanceof Error ? error.message : "Customer status update failed" }, 500);
  }
});
