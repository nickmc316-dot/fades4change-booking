// Private calendar feed for one barber: GET /functions/v1/calendar?token=<calendar_token>
// Google Calendar and iPhone subscribe to this URL. The token is the only key, so it is long and random.
import { createClient } from 'npm:@supabase/supabase-js@2.45.4';

const sb = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, {
  auth: { persistSession: false },
});

const text = (s: string | null | undefined) =>
  String(s ?? '').replace(/\\/g, '\\\\').replace(/;/g, '\\;').replace(/,/g, '\\,').replace(/\r?\n/g, '\\n');
const stamp = (d: string | Date) => new Date(d).toISOString().replace(/[-:]/g, '').replace(/\.\d{3}/, '');
function fold(line: string) {
  const out: string[] = [];
  while (line.length > 73) { out.push(line.slice(0, 73)); line = ' ' + line.slice(73); }
  out.push(line);
  return out.join('\r\n');
}
const notFound = () => new Response('Calendar not found', { status: 404 });

Deno.serve(async (req) => {
  const token = new URL(req.url).searchParams.get('token') ?? '';
  if (!/^[0-9a-f]{36}$/.test(token)) return notFound();

  const { data: barber } = await sb.from('barbers')
    .select('id, name, active, shops(name, address)')
    .eq('calendar_token', token).maybeSingle();
  if (!barber || !barber.active) return notFound();

  const from = new Date(Date.now() - 14 * 864e5).toISOString();
  const to = new Date(Date.now() + 90 * 864e5).toISOString();
  const { data: rows, error } = await sb.from('bookings')
    .select('id, starts_at, ends_at, status, client_name, client_phone, cut_notes, services(name)')
    .eq('barber_id', barber.id).in('status', ['confirmed', 'done'])
    .gte('starts_at', from).lt('starts_at', to).order('starts_at');
  if (error) return new Response('Calendar unavailable', { status: 500 });

  // deno-lint-ignore no-explicit-any
  const shop: any = barber.shops;
  const now = stamp(new Date());
  const lines = [
    'BEGIN:VCALENDAR', 'VERSION:2.0', 'PRODID:-//Fades 4 Change//Booking//EN', 'CALSCALE:GREGORIAN', 'METHOD:PUBLISH',
    `X-WR-CALNAME:${text(shop?.name ? 'Fades 4 Change · ' + barber.name : barber.name)}`,
    'X-PUBLISHED-TTL:PT1H', 'REFRESH-INTERVAL;VALUE=DURATION:PT1H',
  ];
  // deno-lint-ignore no-explicit-any
  for (const b of (rows ?? []) as any[]) {
    const desc = [`Phone: ${b.client_phone}`, b.cut_notes ? `Cut notes: ${b.cut_notes}` : ''].filter(Boolean).join('\n');
    lines.push(
      'BEGIN:VEVENT',
      `UID:${b.id}@fades4change`,
      `DTSTAMP:${now}`,
      `DTSTART:${stamp(b.starts_at)}`,
      `DTEND:${stamp(b.ends_at)}`,
      `SUMMARY:${text(`${b.client_name} · ${b.services?.name ?? 'Appointment'}`)}`,
      `DESCRIPTION:${text(desc)}`,
      `LOCATION:${text(shop?.address)}`,
      'BEGIN:VALARM', 'ACTION:DISPLAY', `DESCRIPTION:${text(b.client_name + ' in 15 minutes')}`, 'TRIGGER:-PT15M', 'END:VALARM',
      'END:VEVENT',
    );
  }
  lines.push('END:VCALENDAR');
  return new Response(lines.map(fold).join('\r\n') + '\r\n', {
    headers: { 'Content-Type': 'text/calendar; charset=utf-8', 'Cache-Control': 'no-store' },
  });
});
