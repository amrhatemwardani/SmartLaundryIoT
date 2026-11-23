import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

function equalHex(a: string, b: string) {
  const left = a.toLowerCase(), right = b.toLowerCase();
  if (left.length !== right.length) return false;
  let mismatch = 0;
  for (let i = 0; i < left.length; i++) mismatch |= left.charCodeAt(i) ^ right.charCodeAt(i);
  return mismatch === 0;
}
async function signHmac(value: string, key: string) {
  const cryptoKey = await crypto.subtle.importKey("raw", new TextEncoder().encode(key), { name: "HMAC", hash: "SHA-512" }, false, ["sign"]);
  const signature = await crypto.subtle.sign("HMAC", cryptoKey, new TextEncoder().encode(value));
  return [...new Uint8Array(signature)].map((b) => b.toString(16).padStart(2, "0")).join("");
}
function signaturePayload(obj: Record<string, any>) {
  return [
    obj.amount_cents, obj.created_at, obj.currency, obj.error_occured,
    obj.has_parent_transaction, obj.id, obj.integration_id, obj.is_3d_secure,
    obj.is_auth, obj.is_capture, obj.is_refunded, obj.is_standalone_payment,
    obj.is_voided, obj.order?.id, obj.owner, obj.pending,
    obj.source_data?.pan, obj.source_data?.sub_type, obj.source_data?.type, obj.success,
  ].map((v) => String(v ?? "")).join("");
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return new Response("Method not allowed", { status: 405 });
  const hmacSecret = Deno.env.get("PAYMOB_HMAC_SECRET");
  const url = Deno.env.get("SUPABASE_URL");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!hmacSecret || !url || !serviceKey) return new Response("Webhook unavailable", { status: 503 });
  let body: Record<string, any>;
  try { body = await req.json(); } catch { return new Response("Invalid callback", { status: 400 }); }
  const obj = body.obj || body;
  const provided = String(body.hmac || obj.hmac || new URL(req.url).searchParams.get("hmac") || "");
  if (!provided || !obj.order?.id || !obj.id) return new Response("Invalid callback", { status: 400 });
  const expected = await signHmac(signaturePayload(obj), hmacSecret);
  if (!equalHex(provided, expected)) return new Response("Invalid signature", { status: 401 });

  const integrations = [Deno.env.get("PAYMOB_CARD_INTEGRATION_ID"), Deno.env.get("PAYMOB_WALLET_INTEGRATION_ID")].filter(Boolean).map(Number);
  if (!integrations.includes(Number(obj.integration_id))) return new Response("Unexpected integration", { status: 400 });
  const success = obj.success === true && obj.pending !== true && obj.error_occured !== true && obj.is_refunded !== true && obj.is_voided !== true;
  const reference = obj.order?.merchant_order_id || obj.merchant_order_id || obj.payment_key_claims?.extra?.merchant_reference || null;
  const service = createClient(url, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } });
  const { data, error } = await service.rpc("apply_paymob_callback", {
    p_reference: reference, p_order_id: String(obj.order.id), p_transaction_id: String(obj.id),
    p_amount_cents: Number(obj.amount_cents), p_currency: String(obj.currency || ""), p_success: success,
  });
  if (error) {
    console.error("Verified Paymob callback could not be applied:", error.message);
    return new Response("Payment update failed", { status: 500 });
  }
  return Response.json({ received: true, status: data?.status || "processed" }, { status: 200 });
});
