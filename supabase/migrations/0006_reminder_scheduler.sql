-- Runs the reminders function every 5 minutes. The shared secret lives in a locked table:
-- only the database itself and server-side functions (service role) can read it.
create extension if not exists pg_cron;
create extension if not exists pg_net;

create table public.cron_settings (
  id int primary key check (id = 1),
  secret text not null
);
alter table public.cron_settings enable row level security;
revoke all on public.cron_settings from anon, authenticated;
insert into public.cron_settings (id, secret) values (1, encode(extensions.gen_random_bytes(24), 'hex'));

select cron.schedule(
  'f4c-reminders',
  '*/5 * * * *',
  $$
  select net.http_post(
    url := 'https://ebhxsaiihvdvcbjagxqv.supabase.co/functions/v1/reminders',
    headers := jsonb_build_object('Content-Type', 'application/json',
                                  'x-cron-secret', (select secret from public.cron_settings where id = 1)),
    body := '{}'::jsonb,
    timeout_milliseconds := 30000
  );
  $$
);
