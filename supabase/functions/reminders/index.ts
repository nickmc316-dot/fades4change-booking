// Sends due reminders. Two callers:
//  1. The database scheduler every 5 minutes (header x-cron-secret matches public.cron_settings).
//  2. A signed-in barber pressing "Send test text" (body {"test": true} with their login token).
// Email goes out through the shop Gmail (SMTP_USER / SMTP_PASS secrets) on port 465.
import { createClient } from 'npm:@supabase/supabase-js@2.45.4';
import nodemailer from 'npm:nodemailer@6.9.14';

const sb = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, {
  auth: { persistSession: false },
});

// Email-to-text addresses for carriers that still deliver them.
const GATEWAYS: Record<string, string> = {
  verizon: 'vtext.com',
  tmobile: 'tmomail.net',
  uscellular: 'email.uscc.net',
  googlefi: 'msg.fi.google.com',
};
const CLIENT_LEAD_MIN = 120; // client reminder ~2 hours before
const BARBER_LEAD_MIN = 15;  // barber heads-up ~15 minutes before
const RUN_EVERY_MIN = 5;

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } });

function mailer() {
  const user = Deno.env.get('SMTP_USER'), pass = Deno.env.get('SMTP_PASS');
  if (!user || !pass) throw new Error('smtp_not_configured');
  return {
    from: `"Fades 4 Change" <${user}>`,
    t: nodemailer.createTransport({ host: 'smtp.gmail.com', port: 465, secure: true, auth: { user, pass } }),
  };
}
const smsAddress = (phone: string | null, carrier: string | null) => {
  const digits = (phone ?? '').replace(/\D/g, '').replace(/^1(?=\d{10}$)/, '');
  const domain = carrier ? GATEWAYS[carrier] : undefined;
  return digits.length === 10 && domain ? `${digits}@${domain}` : null;
};
const when = (iso: string, tz: string, opts: Intl.DateTimeFormatOptions) =>
  new Date(iso).toLocaleString('en-US', { timeZone: tz, ...opts });

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  const body = await req.json().catch(() => ({}));

  // ── Test text for the signed-in barber ──
  if (body?.test) {
    const jwt = (req.headers.get('Authorization') ?? '').replace(/^Bearer\s+/i, '');
    const { data: u } = await sb.auth.getUser(jwt);
    if (!u?.user) return json({ error: 'not_signed_in' }, 401);
    const { data: me } = await sb.from('barbers').select('name, phone, carrier').eq('user_id', u.user.id).maybeSingle();
    if (!me) return json({ error: 'not_on_team' }, 403);
    const to = smsAddress(me.phone, me.carrier);
    if (!to) return json({ error: 'no_text_route' }, 400);
    try {
      const m = mailer();
      await m.t.sendMail({ from: m.from, to, subject: '', text: `Fades 4 Change: test text for ${me.name.split(' ')[0]}. Heads-up alerts will look like this.` });
      return json({ sent: true });
    } catch (e) {
      return json({ error: String((e as Error).message) }, 500);
    }
  }

  // ── Scheduled run ──
  const { data: cfg } = await sb.from('cron_settings').select('secret').eq('id', 1).maybeSingle();
  if (!cfg || req.headers.get('x-cron-secret') !== cfg.secret) return json({ error: 'forbidden' }, 403);

  let m;
  try { m = mailer(); } catch (e) { return json({ error: String((e as Error).message) }, 500); }
  const now = Date.now();
  const report = { clients: 0, barbers: 0, failed: 0 };

  // Client reminders: confirmed bookings starting within the next ~2 hours, with an email, not yet reminded.
  const { data: due } = await sb.from('bookings')
    .select('id, starts_at, client_name, client_email, services(name), barbers(name), shops(name, address, timezone)')
    .eq('status', 'confirmed').is('client_reminded_at', null).not('client_email', 'is', null)
    .gt('starts_at', new Date(now).toISOString())
    .lte('starts_at', new Date(now + (CLIENT_LEAD_MIN + RUN_EVERY_MIN) * 60000).toISOString());
  // deno-lint-ignore no-explicit-any
  for (const b of (due ?? []) as any[]) {
    const tz = b.shops?.timezone ?? 'America/New_York';
    const time = when(b.starts_at, tz, { hour: 'numeric', minute: '2-digit' });
    const day = when(b.starts_at, tz, { weekday: 'long', month: 'long', day: 'numeric' });
    try {
      await m.t.sendMail({
        from: m.from, to: b.client_email,
        subject: `Reminder: your cut today at ${time}`,
        text: `Hi ${b.client_name.split(' ')[0]},\n\nSee you today, ${day}, at ${time}.\n\n` +
          `${b.services?.name} with ${b.barbers?.name}\n${b.shops?.name}\n${b.shops?.address}\n\n` +
          `Running late or can't make it? Call or text the shop.\n`,
      });
      await sb.from('bookings').update({ client_reminded_at: new Date().toISOString() }).eq('id', b.id);
      report.clients++;
    } catch { report.failed++; }
  }

  // Barber heads-up: confirmed bookings starting within the next ~15 minutes, not yet sent.
  const { data: soon } = await sb.from('bookings')
    .select('id, starts_at, client_name, cut_notes, services(name), barbers(name, phone, carrier, notify_method), shops(timezone)')
    .eq('status', 'confirmed').is('barber_notified_at', null)
    .gt('starts_at', new Date(now).toISOString())
    .lte('starts_at', new Date(now + (BARBER_LEAD_MIN + RUN_EVERY_MIN) * 60000).toISOString());
  // deno-lint-ignore no-explicit-any
  for (const b of (soon ?? []) as any[]) {
    const to = b.barbers?.notify_method === 'email_sms' ? smsAddress(b.barbers.phone, b.barbers.carrier) : null;
    if (!to) continue; // app notifications come in a later update
    const time = when(b.starts_at, b.shops?.timezone ?? 'America/New_York', { hour: 'numeric', minute: '2-digit' });
    const notes = b.cut_notes ? ` Notes: ${b.cut_notes}` : '';
    try {
      await m.t.sendMail({ from: m.from, to, subject: '', text: `Heads up: ${b.client_name} at ${time}. ${b.services?.name}.${notes}`.slice(0, 300) });
      await sb.from('bookings').update({ barber_notified_at: new Date().toISOString() }).eq('id', b.id);
      report.barbers++;
    } catch { report.failed++; }
  }

  return json(report);
});
