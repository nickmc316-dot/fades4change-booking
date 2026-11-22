// Starts a Clover Hosted Checkout for a booking's deposit and returns the payment page link.
// POST { booking_id }  ->  { href }
import { createClient } from 'npm:@supabase/supabase-js@2.45.4';

const sb = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, {
  auth: { persistSession: false },
});
const SITE = 'https://fades4change.vercel.app';
const CLOVER_API = { sandbox: 'https://apisandbox.dev.clover.com', production: 'https://api.clover.com' } as const;

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } });

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  const { booking_id } = await req.json().catch(() => ({}));
  if (!/^[0-9a-f-]{36}$/.test(booking_id ?? '')) return json({ error: 'bad_booking' }, 400);

  const { data: b } = await sb.from('bookings')
    .select('id, shop_id, status, payment_ref, deposit_cents, starts_at, client_name, client_email, services(name), barbers(name), shops(name, timezone)')
    .eq('id', booking_id).maybeSingle();
  if (!b) return json({ error: 'bad_booking' }, 404);
  if (b.status !== 'pending') return json({ error: 'not_waiting_for_payment' }, 409);
  if (b.payment_ref) return json({ error: 'already_started' }, 409);

  const { data: cfg } = await sb.from('payment_settings').select('*').eq('shop_id', b.shop_id).maybeSingle();
  if (!cfg?.enabled || !cfg.merchant_id || !cfg.private_token) return json({ error: 'payments_off' }, 503);

  // deno-lint-ignore no-explicit-any
  const x = b as any;
  const tz = x.shops?.timezone ?? 'America/New_York';
  const when = new Date(b.starts_at).toLocaleString('en-US', { timeZone: tz, weekday: 'short', month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit' });
  const [first, ...rest] = String(b.client_name).trim().split(/\s+/);
  const customer: Record<string, string> = { firstName: first };
  if (rest.length) customer.lastName = rest.join(' ');
  if (b.client_email) customer.email = b.client_email;

  const res = await fetch(`${CLOVER_API[cfg.environment as 'sandbox' | 'production']}/invoicingcheckoutservice/v1/checkouts`, {
    method: 'POST',
    headers: {
      accept: 'application/json',
      'content-type': 'application/json',
      'X-Clover-Merchant-Id': cfg.merchant_id,
      authorization: `Bearer ${cfg.private_token}`,
    },
    body: JSON.stringify({
      customer,
      redirectUrls: {
        success: `${SITE}/index.html?paid=${b.id}`,
        failure: `${SITE}/index.html?payfail=${b.id}`,
      },
      shoppingCart: {
        lineItems: [{
          name: `Booking deposit: ${x.services?.name ?? 'Appointment'}`,
          note: `${when} with ${x.barbers?.name ?? 'your barber'}. Comes off your total.`.slice(0, 120),
          price: b.deposit_cents,
          unitQty: 1,
        }],
      },
    }),
  });
  const out = await res.json().catch(() => ({}));
  if (!res.ok || !out.href || !out.checkoutSessionId) {
    console.error('clover_checkout_failed', res.status, JSON.stringify(out).slice(0, 500));
    return json({ error: 'clover_error', status: res.status }, 502);
  }
  await sb.from('bookings').update({ payment_ref: out.checkoutSessionId }).eq('id', b.id).is('payment_ref', null);
  return json({ href: out.href });
});
