# Fades 4 Change booking

Online booking for Fades 4 Change Barbershop / Barberia, 311 Spartanburg Hwy, Suite A, Wellford, SC.

## What's here

| Path | What it is |
|---|---|
| `web/index.html` | Client booking page (pick service, barber, time; leaves name, phone, email, cut notes) |
| `web/staff.html` | Staff login. Owner sees the whole shop, the team list and every rent statement; each barber sees only their own clients and statement |
| `web/config.js` | Supabase project URL, public key, shop id, and shop-time helpers |
| `web/styles.css` | Shared styles |
| `supabase/migrations/` | Database schema, security rules and functions, in the order they were applied |
| `supabase/seed.sql` | The shop's services, prices and barbers |
| `prototype/demo.html` | The original clickable demo (fake data, runs in the browser only) |

## How it works

- **Database:** Supabase project `fades4change` (us-east-1).
- **Booking:** the page calls `create_booking()`, which checks shop hours, the 30-minute grid and
  barber availability. Double-booking a barber is blocked by the database itself.
- **Privacy:** signed-out visitors can only see services, barber names and which times are taken.
  Client details, barber phone numbers and rent statements need a staff login.
- **Booth rent:** `rent_statement()` totals paid deposits per barber per week (Monday to Sunday)
  against weekly rent. The owner marks a week settled, then the barber confirms it.

## Still to build

1. Custom email sending (Supabase's built-in email only reaches project team members)
2. Calendar subscription link per barber
3. Email reminders to clients and email-to-text alerts to barbers
4. Online deposits (Stripe)
5. Hosting on a real web address

## Running locally

Open `web/index.html` in a browser, or serve the `web/` folder with any static file server.
