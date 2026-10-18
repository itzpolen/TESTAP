function returnPage(status: "success" | "cancel"): string {
  const title = status === "success" ? "Payment submitted" : "Checkout cancelled";
  const message = status === "success"
    ? "Return to AquaDirect. The app will check your payment status."
    : "No payment confirmation was received. Return to AquaDirect to retry if you want.";

  return `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <meta name="theme-color" content="#ffffff">
  <title>${title} | AquaDirect</title>
  <style>
    body { font-family: Arial, sans-serif; margin: 0; padding: 24px; color: #17243a; background: #f4f8fc; }
    main { max-width: 440px; margin: 12vh auto; padding: 28px; background: white; border-radius: 16px; }
    h1 { font-size: 1.5rem; }
    p { line-height: 1.6; }
  </style>
</head>
<body>
  <main>
    <h1>${title}</h1>
    <p>${message}</p>
    <p>Payment status is confirmed by PayMongo and may take a few moments to update.</p>
    <p>You can close this page and return to the AquaDirect app.</p>
  </main>
</body>
</html>`;
}

Deno.serve((request) => {
  if (request.method !== "GET" && request.method !== "HEAD") {
    return new Response("Method not allowed", {
      status: 405,
      headers: { Allow: "GET, HEAD", "Content-Type": "text/plain; charset=utf-8" },
    });
  }

  const status = new URL(request.url).searchParams.get("status");
  if (status !== "success" && status !== "cancel") {
    return new Response("Use status=success or status=cancel.", {
      status: 400,
      headers: { "Content-Type": "text/plain; charset=utf-8" },
    });
  }

  return new Response(request.method === "HEAD" ? null : returnPage(status), {
    headers: {
      "Cache-Control": "no-store",
      "Content-Security-Policy": "default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; frame-ancestors 'none'",
      "Content-Type": "text/html; charset=utf-8",
      "X-Content-Type-Options": "nosniff",
    },
  });
});
