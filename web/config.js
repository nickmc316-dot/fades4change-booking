// Public settings for the browser. The publishable key is meant to be public:
// row level security in the database decides what it can read and write.
window.F4C_CONFIG = {
  supabaseUrl: 'https://ebhxsaiihvdvcbjagxqv.supabase.co',
  supabaseKey: 'sb_publishable_tZXMM5yPhBtoyUgRrG5Low_2bremEtp',
  shopId: '06efc15d-cee1-4954-8751-fb34d5452e35',
};

// Shop-local time helpers (the shop runs on its own time zone, whatever the visitor's is).
window.F4C_TIME = (function () {
  function offsetMs(ts, tz) {
    const parts = new Intl.DateTimeFormat('en-US', {
      timeZone: tz, hourCycle: 'h23', year: 'numeric', month: '2-digit', day: '2-digit',
      hour: '2-digit', minute: '2-digit', second: '2-digit',
    }).formatToParts(new Date(ts));
    const v = Object.fromEntries(parts.map(p => [p.type, p.value]));
    return Date.UTC(+v.year, +v.month - 1, +v.day, +v.hour, +v.minute, +v.second) - ts;
  }
  // "2026-11-24", 600 (10:00am) in tz -> Date
  function toUtc(day, minutes, tz) {
    const [y, m, d] = day.split('-').map(Number);
    const guess = Date.UTC(y, m - 1, d, Math.floor(minutes / 60), minutes % 60);
    let ts = guess - offsetMs(guess, tz);
    ts = guess - offsetMs(ts, tz);
    return new Date(ts);
  }
  function todayIn(tz) {
    return new Intl.DateTimeFormat('en-CA', { timeZone: tz }).format(new Date()); // YYYY-MM-DD
  }
  function addDays(day, n) {
    const [y, m, d] = day.split('-').map(Number);
    return new Date(Date.UTC(y, m - 1, d + n)).toISOString().slice(0, 10);
  }
  function dow(day) {
    const [y, m, d] = day.split('-').map(Number);
    return new Date(Date.UTC(y, m - 1, d)).getUTCDay();
  }
  function label(day, opts) {
    const [y, m, d] = day.split('-').map(Number);
    return new Date(Date.UTC(y, m - 1, d, 12)).toLocaleDateString('en-US', Object.assign({ timeZone: 'UTC' }, opts));
  }
  function fmt(minutes) {
    let h = Math.floor(minutes / 60), mm = minutes % 60, ap = h >= 12 ? 'pm' : 'am';
    h = h % 12 || 12;
    return h + ':' + String(mm).padStart(2, '0') + ap;
  }
  function weekStart(day) { return addDays(day, -((dow(day) + 6) % 7)); } // Monday
  return { toUtc, todayIn, addDays, dow, label, fmt, weekStart };
})();
