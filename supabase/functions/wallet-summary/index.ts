import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const headers = (origin: string) => ({
  "Access-Control-Allow-Origin": Deno.env.get("APP_ORIGIN") || origin || "null",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info",
  "Access-Control-Allow-Methods": "GET, OPTIONS",
  "Cache-Control": "no-store",
  "Vary": "Origin",
});
Deno.serve(async (req) => {
  const origin = req.headers.get("origin") || "";
  if (req.method === "OPTIONS") return new Response("ok", { headers: headers(origin) });
  if (req.method !== "GET") return Response.json({ error: "Method not allowed" }, { status: 405, headers: headers(origin) });
  const url = Deno.env.get("SUPABASE_URL")!, anon = Deno.env.get("SUPABASE_ANON_KEY")!, serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const token = (req.headers.get("authorization") || "").match(/^Bearer\s+(.+)$/i)?.[1];
  if (!token) return Response.json({ error: "Sign in required." }, { status: 401, headers: headers(origin) });
  const auth = createClient(url, anon, { auth: { persistSession: false, autoRefreshToken: false } });
  const { data: { user }, error: authError } = await auth.auth.getUser(token);
  if (authError || !user) return Response.json({ error: "Sign in required." }, { status: 401, headers: headers(origin) });
  const service = createClient(url, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } });
  const { data, error } = await service.rpc("get_wallet_balance", { p_user_id: user.id });
  if (error) return Response.json({ error: "Wallet balance unavailable." }, { status: 503, headers: headers(origin) });
  return Response.json({ balanceCents: Number(data || 0), currency: "EGP" }, { headers: headers(origin) });
});
