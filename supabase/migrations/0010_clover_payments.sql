-- Online deposits through Clover Hosted Checkout.
-- The owner saves Clover keys from the app; they can be written but never read back by anyone
-- signed in. Only server-side functions (service role) read them.
create table public.payment_settings (
  shop_id uuid primary key references public.shops(id) on delete cascade,
  provider text not null default 'clover' check (provider in ('clover')),
  environment text not null default 'sandbox' check (environment in ('sandbox', 'production')),
  merchant_id text,
  private_token text,
  webhook_secret text,
  enabled boolean not null default false,
  updated_at timestamptz not null default now()
);
alter table public.payment_settings enable row level security;
revoke all on public.payment_settings from anon, authenticated;
grant select, insert, update, delete on public.payment_settings to service_role;

-- Owner saves settings. Blank fields keep what is already saved.
create function public.set_payment_settings(p_shop uuid, p_environment text, p_merchant_id text,
  p_private_token text, p_webhook_secret text, p_enabled boolean)
returns void language plpgsql volatile security definer set search_path = '' as $$
begin
  if not private.is_shop_owner(p_shop) then raise exception 'not_allowed'; end if;
  if p_environment not in ('sandbox', 'production') then raise exception 'bad_environment'; end if;
  insert into public.payment_settings (shop_id) values (p_shop) on conflict (shop_id) do nothing;
  update public.payment_settings set
    environment = p_environment,
    merchant_id = coalesce(nullif(trim(p_merchant_id), ''), merchant_id),
    private_token = coalesce(nullif(trim(p_private_token), ''), private_token),
    webhook_secret = coalesce(nullif(trim(p_webhook_secret), ''), webhook_secret),
    enabled = p_enabled,
    updated_at = now()
  where shop_id = p_shop;
  if p_enabled and exists (select 1 from public.payment_settings where shop_id = p_shop
      and (merchant_id is null or private_token is null or webhook_secret is null)) then
    raise exception 'missing_keys';
  end if;
end $$;

-- What the owner screen shows: whether it's connected, never the keys themselves.
create function public.payment_status(p_shop uuid)
returns table (environment text, merchant_id_hint text, has_token boolean, has_webhook_secret boolean, enabled boolean)
language sql stable security definer set search_path = '' as $$
  select p.environment,
         case when p.merchant_id is null then null else '…' || right(p.merchant_id, 4) end,
         p.private_token is not null, p.webhook_secret is not null, p.enabled
  from public.payment_settings p
  where p.shop_id = p_shop and private.is_shop_owner(p_shop)
$$;

-- Is online payment on? (The booking page asks this to decide how to label the button.)
create function public.online_payments_enabled(p_shop uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce((select enabled from public.payment_settings where shop_id = p_shop), false)
$$;

-- Bookings waiting on payment hold their slot until paid or expired.
alter table public.bookings drop constraint bookings_status_check;
alter table public.bookings add constraint bookings_status_check
  check (status in ('pending', 'confirmed', 'done', 'noshow', 'cancelled'));
alter table public.bookings drop constraint no_double_booking;
alter table public.bookings add constraint no_double_booking exclude using gist (
  barber_id with =, tstzrange(starts_at, ends_at) with &&
) where (status in ('pending', 'confirmed', 'done'));
alter table public.bookings add column payment_ref text;
alter table public.bookings add column paid_at timestamptz;
create unique index bookings_payment_ref_idx on public.bookings(payment_ref) where payment_ref is not null;

-- busy_times counts held (pending) slots as taken.
create or replace function public.busy_times(p_shop uuid, p_from timestamptz, p_to timestamptz)
returns table (barber_id uuid, starts_at timestamptz, ends_at timestamptz)
language plpgsql stable security definer set search_path = '' as $$
begin
  if p_to - p_from > interval '32 days' then raise exception 'range_too_long'; end if;
  return query
    select k.barber_id, k.starts_at, k.ends_at from public.bookings k
    where k.shop_id = p_shop and k.status in ('pending', 'confirmed', 'done')
      and k.starts_at < p_to and k.ends_at > p_from;
end $$;

-- Online bookings start as 'pending' when payments are on, 'confirmed' otherwise.
create or replace function public.create_booking(
  p_shop uuid, p_service uuid, p_barber uuid, p_starts_at timestamptz,
  p_client_name text, p_client_phone text, p_client_email text default null, p_cut_notes text default null)
returns uuid
language plpgsql volatile security definer set search_path = '' as $$
declare
  v_shop public.shops%rowtype;
  v_svc public.services%rowtype;
  v_ends timestamptz;
  v_local timestamp; v_end_local timestamp;
  v_start_min int; v_end_min int;
  v_id uuid; v_bid uuid;
  v_status text := case when public.online_payments_enabled(p_shop) then 'pending' else 'confirmed' end;
begin
  select * into v_shop from public.shops where id = p_shop;
  if not found then raise exception 'shop_not_found'; end if;
  select * into v_svc from public.services where id = p_service and shop_id = p_shop and active;
  if not found then raise exception 'service_not_found'; end if;
  if length(regexp_replace(coalesce(p_client_phone,''), '\D', '', 'g')) < 10 then raise exception 'bad_phone'; end if;
  if length(trim(coalesce(p_client_name,''))) = 0 then raise exception 'name_required'; end if;
  if p_starts_at < now() + interval '15 minutes' then raise exception 'too_soon'; end if;
  if p_starts_at > now() + interval '90 days' then raise exception 'too_far_ahead'; end if;

  v_ends := p_starts_at + make_interval(mins => v_svc.minutes);
  v_local := p_starts_at at time zone v_shop.timezone;
  v_end_local := v_ends at time zone v_shop.timezone;
  v_start_min := extract(hour from v_local)::int * 60 + extract(minute from v_local)::int;
  v_end_min := extract(hour from v_end_local)::int * 60 + extract(minute from v_end_local)::int;
  if extract(second from v_local) <> 0 or v_start_min % v_shop.slot_minutes <> 0
     or v_start_min < v_shop.open_minute or v_end_local::date <> v_local::date
     or v_end_min > v_shop.close_minute then
    raise exception 'outside_hours';
  end if;

  for v_bid in
    select b.id from public.barbers b
    where b.shop_id = p_shop and b.active and (p_barber is null or b.id = p_barber)
    order by random()
  loop
    begin
      insert into public.bookings (shop_id, barber_id, service_id, starts_at, ends_at,
        client_name, client_phone, client_email, cut_notes, deposit_cents, status)
      values (p_shop, v_bid, p_service, p_starts_at, v_ends,
        trim(p_client_name), p_client_phone, nullif(trim(p_client_email), ''), nullif(trim(p_cut_notes), ''),
        v_shop.deposit_cents, v_status)
      returning id into v_id;
      return v_id;
    exception when exclusion_violation then
      null;
    end;
  end loop;
  raise exception 'slot_taken';
end $$;

-- The booking page checks this after the client returns from Clover. Booking ids are random,
-- and this reveals only the status.
create function public.booking_payment_status(p_booking uuid)
returns table (status text, deposit_paid boolean)
language sql stable security definer set search_path = '' as $$
  select b.status, b.deposit_paid from public.bookings b where b.id = p_booking
$$;

revoke execute on function public.set_payment_settings(uuid, text, text, text, text, boolean),
  public.payment_status(uuid), public.online_payments_enabled(uuid), public.booking_payment_status(uuid)
  from public, anon;
grant execute on function public.set_payment_settings(uuid, text, text, text, text, boolean), public.payment_status(uuid) to authenticated;
grant execute on function public.online_payments_enabled(uuid), public.booking_payment_status(uuid) to anon, authenticated;

-- Release slots whose payment was never finished (Clover sessions expire after 15 minutes).
select cron.schedule('f4c-release-unpaid', '*/5 * * * *', $$
  update public.bookings set status = 'cancelled'
  where status = 'pending' and created_at < now() - interval '20 minutes'
$$);
