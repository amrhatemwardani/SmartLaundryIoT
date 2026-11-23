import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const headers = (origin: string) => ({
  "Access-Control-Allow-Origin": origin || Deno.env.get("APP_ORIGIN") || "*",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info",
  "Access-Control-Allow-Methods": "GET, OPTIONS",
  "Cache-Control": "no-store",
  "Vary": "Origin",
});
const json = (body: unknown, status = 200, origin = "") => Response.json(body, { status, headers: headers(origin) });

Deno.serve(async (req) => {
  const origin = req.headers.get("origin") || "";
  if (req.method === "OPTIONS") return new Response("ok", { headers: headers(origin) });
  if (req.method !== "GET") return json({ error: "Method not allowed" }, 405, origin);
  const token = (req.headers.get("authorization") || "").match(/^Bearer\s+(.+)$/i)?.[1];
  const url = Deno.env.get("SUPABASE_URL")!, anon = Deno.env.get("SUPABASE_ANON_KEY")!, serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  if (!token) return json({ error: "Sign in required." }, 401, origin);
  const authClient = createClient(url, anon, { auth: { persistSession: false, autoRefreshToken: false } });
  const { data: { user }, error: authError } = await authClient.auth.getUser(token);
  if (authError || !user) return json({ error: "Sign in required." }, 401, origin);
  const reference = new URL(req.url).searchParams.get("reference");
  if (!reference || !/^ZC-[a-f0-9]{32}$/i.test(reference)) return json({ error: "Invalid payment reference." }, 400, origin);
  const service = createClient(url, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } });
  const { data, error } = await service.from("payment_attempts")
    .select("special_reference,kind,amount_cents,currency,status,user_id")
    .eq("special_reference", reference).eq("user_id", user.id).maybeSingle();
  if (error || !data) return json({ error: "Payment not found." }, 404, origin);
  return json({ reference: data.special_reference, kind: data.kind, amountCents: data.amount_cents, currency: data.currency, status: data.status }, 200, origin);
});
