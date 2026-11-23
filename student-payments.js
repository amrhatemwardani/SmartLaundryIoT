/* Client-side payment launcher. All prices, reservations, and payment state are controlled by Edge Functions. */
(function () {
  let busy = false;
  const config = () => window.ZC_SUPABASE_CONFIG || {};
  let client = null;

  function notify(message, type = "info") {
    if (window.ZCNotify) window.ZCNotify.show(message, type);
    else window.alert(message);
  }

  async function getClient() {
    if (!window.ZCSupabase) throw new Error("Supabase account service is not configured yet.");
    client = await window.ZCSupabase.ready();
    const { data, error } = await client.auth.getSession();
    if (error || !data.session) throw new Error("Please sign in through the secure university account before paying.");
    return { client, session: data.session };
  }

  async function start(details) {
    if (busy) return;
    busy = true;
    const button = document.getElementById(details.buttonId);
    if (button) button.disabled = true;
    if (window.ZCLoading) window.ZCLoading.show("Connecting to Paymob securely");
    try {
      const { client: supabaseClient, session } = await getClient();
      const cfg = config();
      const keyName = "zcPaymobIdempotencyKey:" + details.kind;
      let idempotencyKey = sessionStorage.getItem(keyName);
      if (!idempotencyKey) {
        idempotencyKey = crypto.randomUUID();
        sessionStorage.setItem(keyName, idempotencyKey);
      }
      const response = await fetch(cfg.url.replace(/\/$/, "") + "/functions/v1/create-paymob-intention", {
        method: "POST",
        headers: {
          "Authorization": "Bearer " + session.access_token,
          "apikey": cfg.publishableKey,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({ ...details, buttonId: undefined, idempotencyKey }),
        cache: "no-store",
      });
      const result = await response.json().catch(() => ({}));
      if (!response.ok || !result.checkoutUrl) throw new Error(result.error || "Could not start secure checkout.");
      sessionStorage.setItem("zcLastPaymobReference", result.reference);
      if (result.isSandbox) {
        // Sandbox mode: notify the user and open the simulator
        notify("Paymob sandbox mode — no real payment will be taken.", "info");
      }
      window.location.assign(result.checkoutUrl);
    } catch (error) {
      notify(error instanceof Error ? error.message : "Payment could not be started.", "error");
      if (window.ZCLoading) window.ZCLoading.hide();
      if (button) button.disabled = false;
      busy = false;
    }
  }

  async function loadWalletBalance() {
    const balanceEl = document.getElementById("walletBalance");
    if (!balanceEl) return;
    try {
      const { client: supabaseClient, session } = await getClient();
      const cfg = config();
      const response = await fetch(cfg.url.replace(/\/$/, "") + "/functions/v1/wallet-summary", {
        headers: { "Authorization": "Bearer " + session.access_token, "apikey": cfg.publishableKey },
        cache: "no-store",
      }).catch(() => null);

      if (response && response.ok) {
        const result = await response.json().catch(() => ({}));
        if (Number.isInteger(result.balanceCents)) {
          const balance = "EGP " + (result.balanceCents / 100).toFixed(2);
          balanceEl.textContent = balance;
          const checkoutBalance = document.getElementById("checkoutWalletBalance");
          if (checkoutBalance) checkoutBalance.textContent = balance;
          return;
        }
      }

      // Direct fallback via Supabase RPC if Edge Function is pending deployment
      const { data: bal, error: balErr } = await supabaseClient.rpc("get_wallet_balance");
      if (!balErr && Number.isInteger(bal)) {
        const balance = "EGP " + (bal / 100).toFixed(2);
        balanceEl.textContent = balance;
        const checkoutBalance = document.getElementById("checkoutWalletBalance");
        if (checkoutBalance) checkoutBalance.textContent = balance;
      }
    } catch { /* Keep the UI in its unconnected state until secure auth is configured. */ }
  }

  window.ZCPayments = { start, loadWalletBalance };
  document.addEventListener("DOMContentLoaded", loadWalletBalance);
})();
