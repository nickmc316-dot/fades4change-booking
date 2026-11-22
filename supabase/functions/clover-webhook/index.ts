// Receives Clover Hosted Checkout payment notices and marks the matching booking paid.
// Checks the Clover-Signature header: HMAC-SHA256(signing secret, "<t>.<raw body>") must equal v1.
import { createClient } from 'npm:@supabase/supabase-js@2.45.4';

const sb = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, {
  auth: { persistSession: false },
});
const MAX_AGE_SEC = 600;

async function hmacHex(secret: string, msg: string) {
  const key = await crypto.subtle.importKey('raw', new TextEncoder().encode(secret), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  const sig = await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(msg));
  return Array.from(new Uint8Array(sig)).map((b) => b.toString(16).padStart(2, '0')).join('');
}
function safeEqual(a: string, b: string) {
  if (a.length !== b.length) return false;
  let r = 0;
  for (let i = 0; i < a.length; i++) r |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return r === 0;
}
// Clover's docs show the fields capitalised in places; accept either.
// deno-lint-ignore no-explicit-any
const pick = (o: any, k: string) => o?.[k] ?? o?.[k[0].toUpperCase() + k.slice(1)];

Deno.serve(async (req) => {
  if (req.method !== 'POST') return new Response('ok');
  const raw = await req.text();
  // deno-lint-ignore no-explicit-any
  let body: any;
  try { body = JSON.parse(raw); } catch { return new Response('bad body', { status: 400 }); }

  const merchantId = pick(body, 'merchantId');
  const { data: cfg } = await sb.from('payment_settings').select('shop_id, merchant_id, webhook_secret').eq('merchant_id', merchantId).maybeSingle();
  if (!cfg?.webhook_secret) return new Response('unknown merchant', { status: 401 });

  const header = req.headers.get('clover-signature') ?? '';
  const parts = Object.fromEntries(header.split(',').map((p) => p.trim().split('=') as [string, string]));
  const t = parts.t, v1 = (parts.v1 ?? '').toLowerCase();
  if (!t || !v1) return new Response('missing signature', { status: 401 });
  if (Math.abs(Date.now() / 1000 - Number(t)) > MAX_AGE_SEC) return new Response('stale', { status: 401 });
  if (!safeEqual(await hmacHex(cfg.webhook_secret, `${t}.${raw}`), v1)) return new Response('bad signature', { status: 401 });

  const status = String(pick(body, 'status') ?? '').toUpperCase();
  const type = String(pick(body, 'type') ?? '').toUpperCase();
  // Clover sends the session id as `checkoutSessionId` (its docs call it `data`; accept both).
  const sessionId = pick(body, 'checkoutSessionId') ?? pick(body, 'data');
  if (type && type !== 'PAYMENT') return new Response('ignored');
  if (status !== 'APPROVED' || typeof sessionId !== 'string') return new Response('noted');

  const { data: b } = await sb.from('bookings').select('id, status')
    .eq('shop_id', cfg.shop_id).eq('payment_ref', sessionId).maybeSingle();
  if (!b) { console.log('clover_webhook_no_match', JSON.stringify({ keys: Object.keys(body), status, type })); return new Response('no matching booking'); }

  const paid = { deposit_paid: true, paid_at: new Date().toISOString() };
  if (b.status === 'pending' || b.status === 'cancelled') {
    // Confirm it. If the slot was released and someone else took it, keep it cancelled but
    // record the payment so the owner sees a deposit to refund.
    const { error } = await sb.from('bookings').update({ ...paid, status: 'confirmed' }).eq('id', b.id);
    if (error) await sb.from('bookings').update(paid).eq('id', b.id);
  } else {
    await sb.from('bookings').update(paid).eq('id', b.id);
  }
  return new Response('ok');
});
