import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const cors = (origin: string) => ({
  "Access-Control-Allow-Origin": origin || Deno.env.get("APP_ORIGIN") || "*",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Vary": "Origin",
});
const json = (body: unknown, status = 200, origin = "") =>
  new Response(JSON.stringify(body), { status, headers: { ...cors(origin), "Content-Type": "application/json", "Cache-Control": "no-store" } });

Deno.serve(async (req) => {
  const origin = req.headers.get("origin") || "";
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors(origin) });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405, origin);

  const url = Deno.env.get("SUPABASE_URL")!;
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY")!;
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const secretKey = Deno.env.get("PAYMOB_SECRET_KEY");
  const publicKey = Deno.env.get("PAYMOB_PUBLIC_KEY");
  const appOrigin = Deno.env.get("APP_ORIGIN") || origin || "*";
  const hmacSecret = Deno.env.get("PAYMOB_HMAC_SECRET");
  const integrationFor = { card: Deno.env.get("PAYMOB_CARD_INTEGRATION_ID"), wallet: Deno.env.get("PAYMOB_WALLET_INTEGRATION_ID") };

  const authorization = req.headers.get("authorization") || "";
  const bearer = authorization.match(/^Bearer\s+(.+)$/i)?.[1];
  if (!bearer) return json({ error: "Sign in with your university account to continue." }, 401, origin);

  const authClient = createClient(url, anonKey, { auth: { persistSession: false, autoRefreshToken: false } });
  const { data: authData, error: authError } = await authClient.auth.getUser(bearer);
  const user = authData?.user;
  if (authError || !user || !user.email || !user.email.toLowerCase().endsWith("@zewailcity.edu.eg") || !user.email_confirmed_at) {
    return json({ error: "A verified Zewail City student account is required." }, 401, origin);
  }

  const service = createClient(url, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } });
  const { data: profile, error: profileError } = await service.from("student_profiles")
    .select("full_name,university_email,phone_number,dorm_class,approval_status,approved_at")
    .eq("user_id", user.id).maybeSingle();
  if (profileError || !profile || !profile.approved_at || profile.university_email.toLowerCase() !== user.email.toLowerCase()) {
    return json({ error: "Your student account must be approved by the dorm supervisor before payment." }, 403, origin);
  }

  let body: Record<string, unknown>;
  try { body = await req.json(); } catch { return json({ error: "Invalid request." }, 400, origin); }
  const kind = body.kind === "ticket" || body.kind === "wallet_topup" ? body.kind : null;
  const paymentMethod = body.paymentMethod === "card" || body.paymentMethod === "wallet" ? body.paymentMethod : null;
  const idempotencyKey = typeof body.idempotencyKey === "string" && /^[0-9a-f-]{36}$/i.test(body.idempotencyKey) ? body.idempotencyKey : null;
  if (!kind || !paymentMethod || !idempotencyKey) return json({ error: "Payment details are incomplete." }, 400, origin);

  const amountCents = kind === "wallet_topup" && Number.isInteger(body.amountCents) ? Number(body.amountCents) : null;
  const machineKey = kind === "ticket" && typeof body.machineKey === "string" ? body.machineKey : null;
  const slotStart = kind === "ticket" && typeof body.slotStart === "string" ? body.slotStart : null;
  const { data: started, error: startError } = await service.rpc("begin_payment_attempt", {
    p_user_id: user.id, p_idempotency_key: idempotencyKey, p_kind: kind,
    p_payment_method: paymentMethod, p_amount_cents: amountCents,
    p_machine_key: machineKey, p_slot_start: slotStart,
  });
  if (startError || !started) {
    const detail = startError?.message || "";
    const message = detail.includes("selected slot") ? "That machine slot is no longer available. Choose another time." : "Could not reserve this payment. Review the details and try again.";
    return json({ error: message }, 409, origin);
  }

  if (started.status !== "pending") return json({ error: "This payment attempt is no longer active." }, 409, origin);

  // Check if live/sandbox Paymob credentials are fully configured
  const hasLivePaymob = Boolean(secretKey && publicKey && hmacSecret && integrationFor[paymentMethod]);

  if (!hasLivePaymob) {
    // Paymob Sandbox Simulator Mode
    const simCheckoutUrl = new URL((origin || appOrigin).replace(/\/$/, "") + "/paymob-simulator.html");
    simCheckoutUrl.searchParams.set("reference", String(started.reference));
    simCheckoutUrl.searchParams.set("kind", String(kind));
    simCheckoutUrl.searchParams.set("method", String(paymentMethod));
    simCheckoutUrl.searchParams.set("amount", String(started.amount_cents));

    await service.rpc("attach_paymob_intention", {
      p_reference: started.reference,
      p_intention_id: "sim_int_" + started.reference,
      p_order_id: "sim_ord_" + started.reference,
      p_client_secret: "sim_secret_" + started.reference,
    }).catch(() => null);

    return json({ checkoutUrl: simCheckoutUrl.toString(), reference: started.reference, isSandbox: true }, 200, origin);
  }

  const integrationId = integrationFor[paymentMethod]!;
  if (started.client_secret) {
    const checkoutUrl = new URL("https://eg.checkout.paymob.com/");
    checkoutUrl.searchParams.set("publicKey", publicKey!);
    checkoutUrl.searchParams.set("clientSecret", started.client_secret);
    return json({ checkoutUrl: checkoutUrl.toString(), reference: started.reference }, 200, origin);
  }
  if (started.reused) {
    return json({ error: "This payment is already being prepared. Check its status before trying again." }, 409, origin);
  }

  const amount = Number(started.amount_cents);
  const billingName = String(profile.full_name || "Zewail City Student").trim().split(/\s+/);
  const firstName = billingName[0] || "Student";
  const lastName = billingName.slice(1).join(" ") || "Zewail";
  const notificationUrl = url + "/functions/v1/paymob-webhook";
  const redirectUrl = new URL((origin || appOrigin).replace(/\/$/, "") + "/payment-result.html");
  redirectUrl.searchParams.set("reference", String(started.reference));

  try {
    const response = await fetch("https://accept.paymob.com/v1/intention/", {
      method: "POST",
      headers: { "Authorization": "Token " + secretKey, "Content-Type": "application/json" },
      body: JSON.stringify({
        amount, currency: "EGP", payment_methods: [Number(integrationId)],
        items: [{ name: kind === "ticket" ? "Dorm laundry ticket" : "Student wallet top-up", amount, description: kind === "ticket" ? "Zewail City dorm laundry slot" : "Wallet top-up", quantity: 1 }],
        billing_data: {
          apartment: "NA", first_name: firstName, last_name: lastName,
          street: "NA", building: "NA", phone_number: profile.phone_number,
          city: "6th of October City", country: "EG", email: profile.university_email,
          floor: "NA", state: "Giza", postal_code: "NA",
        },
        special_reference: started.reference, expiration: 900,
        notification_url: notificationUrl, redirection_url: redirectUrl.toString(),
        extras: { app: "zc-dorm-laundry" },
      }),
    });
    const intention = await response.json().catch(() => ({}));
    if (!response.ok || !intention.client_secret) {
      await service.rpc("fail_payment_attempt", { p_reference: started.reference });
      console.error("Paymob intention rejected:", response.status);
      return json({ error: "Paymob could not start checkout. No payment was taken." }, 502, origin);
    }
    const { error: attachError } = await service.rpc("attach_paymob_intention", {
      p_reference: started.reference,
      p_intention_id: String(intention.id || ""),
      p_order_id: String(intention.intention_order_id || intention.order?.id || ""),
      p_client_secret: String(intention.client_secret),
    });
    if (attachError) {
      await service.rpc("fail_payment_attempt", { p_reference: started.reference });
      return json({ error: "Could not safely save the payment reference. No checkout was opened." }, 503, origin);
    }
    const checkoutUrl = new URL("https://eg.checkout.paymob.com/");
    checkoutUrl.searchParams.set("publicKey", publicKey!);
    checkoutUrl.searchParams.set("clientSecret", intention.client_secret);
    return json({ checkoutUrl: checkoutUrl.toString(), reference: started.reference }, 200, origin);
  } catch (error) {
    await service.rpc("fail_payment_attempt", { p_reference: started.reference });
    console.error("Paymob checkout initialization failed:", error instanceof Error ? error.message : "unknown");
    return json({ error: "Payment service is temporarily unavailable. No payment was taken." }, 502, origin);
  }
});
