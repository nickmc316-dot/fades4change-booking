-- Fades 4 Change booking: core schema, row level security and booking functions.

create extension if not exists btree_gist with schema extensions;

-- ── Tables ────────────────────────────────────────────────────────────────
create table public.shops (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  address text,
  timezone text not null default 'America/New_York',
  open_minute int not null default 360 check (open_minute between 0 and 1439),
  close_minute int not null default 1260 check (close_minute between 1 and 1440),
  slot_minutes int not null default 30 check (slot_minutes between 5 and 240),
  deposit_cents int not null default 1000 check (deposit_cents >= 0),
  weekly_rent_cents int not null default 15000 check (weekly_rent_cents >= 0),
  appointment_only_dows int[] not null default '{0}',
  created_at timestamptz not null default now(),
  check (close_minute > open_minute)
);

create table public.barbers (
  id uuid primary key default gen_random_uuid(),
  shop_id uuid not null references public.shops(id) on delete cascade,
  user_id uuid unique references auth.users(id) on delete set null,
  email text,
  name text not null check (length(trim(name)) between 1 and 80),
  specialty text check (length(specialty) <= 80),
  phone text,
  carrier text check (carrier in ('verizon','tmobile','att','uscellular','cricket','metro','boost','googlefi','other')),
  notify_method text not null default 'push' check (notify_method in ('email_sms','push')),
  role text not null default 'barber' check (role in ('owner','barber')),
  active boolean not null default true,
  calendar_token text not null unique default encode(extensions.gen_random_bytes(18), 'hex'),
  created_at timestamptz not null default now()
);
create index barbers_shop_idx on public.barbers(shop_id);
create unique index barbers_shop_email_idx on public.barbers(shop_id, lower(email)) where email is not null;

create table public.services (
  id uuid primary key default gen_random_uuid(),
  shop_id uuid not null references public.shops(id) on delete cascade,
  name text not null,
  minutes int not null check (minutes between 5 and 480),
  price_cents int not null check (price_cents >= 0),
  sort int not null default 0,
  active boolean not null default true
);
create index services_shop_idx on public.services(shop_id);

create table public.bookings (
  id uuid primary key default gen_random_uuid(),
  shop_id uuid not null references public.shops(id) on delete cascade,
  barber_id uuid not null references public.barbers(id),
  service_id uuid not null references public.services(id),
  starts_at timestamptz not null,
  ends_at timestamptz not null,
  status text not null default 'confirmed' check (status in ('confirmed','done','noshow','cancelled')),
  client_name text not null check (length(trim(client_name)) between 1 and 80),
  client_phone text not null check (length(client_phone) <= 30),
  client_email text check (length(client_email) <= 254),
  cut_notes text check (length(cut_notes) <= 500),
  deposit_cents int not null default 0,
  deposit_paid boolean not null default false,
  client_reminded_at timestamptz,
  barber_notified_at timestamptz,
  created_at timestamptz not null default now(),
  check (ends_at > starts_at),
  constraint no_double_booking exclude using gist (
    barber_id with =, tstzrange(starts_at, ends_at) with &&
  ) where (status in ('confirmed','done'))
);
create index bookings_barber_time_idx on public.bookings(barber_id, starts_at);
create index bookings_shop_time_idx on public.bookings(shop_id, starts_at);
create index bookings_service_idx on public.bookings(service_id);

-- Weekly booth-rent sign-off. balance_cents > 0 means the shop owes the barber.
create table public.rent_settlements (
  id uuid primary key default gen_random_uuid(),
  shop_id uuid not null references public.shops(id) on delete cascade,
  barber_id uuid not null references public.barbers(id) on delete cascade,
  week_start date not null check (extract(isodow from week_start) = 1),
  balance_cents int not null,
  owner_marked_at timestamptz not null default now(),
  barber_confirmed_at timestamptz,
  unique (barber_id, week_start)
);
create index rent_settlements_shop_idx on public.rent_settlements(shop_id);

-- ── Helpers ───────────────────────────────────────────────────────────────
create function public.current_barber_id() returns uuid
language sql stable security definer set search_path = '' as $$
  select id from public.barbers where user_id = auth.uid() and active
$$;

create function public.is_shop_owner(p_shop uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.barbers
                 where user_id = auth.uid() and shop_id = p_shop and role = 'owner' and active)
$$;

-- ── Row level security ────────────────────────────────────────────────────
alter table public.shops enable row level security;
alter table public.barbers enable row level security;
alter table public.services enable row level security;
alter table public.bookings enable row level security;
alter table public.rent_settlements enable row level security;

-- Shops and services are public (the booking page needs them).
create policy shops_read on public.shops for select to anon, authenticated using (true);
create policy shops_owner_update on public.shops for update to authenticated
  using ((select public.is_shop_owner(id))) with check ((select public.is_shop_owner(id)));

create policy services_read on public.services for select to anon, authenticated
  using (active or (select public.is_shop_owner(shop_id)));
create policy services_owner_insert on public.services for insert to authenticated
  with check ((select public.is_shop_owner(shop_id)));
create policy services_owner_update on public.services for update to authenticated
  using ((select public.is_shop_owner(shop_id))) with check ((select public.is_shop_owner(shop_id)));

-- Barber rows hold phone numbers and carriers: only the barber and the owner see them.
-- The public booking page gets names through public_barbers().
revoke all on public.barbers from anon;
revoke insert, update, delete on public.barbers from authenticated;
grant update (name, specialty, phone, carrier, notify_method) on public.barbers to authenticated;
grant insert (shop_id, email, name, specialty, role) on public.barbers to authenticated;
create policy barbers_read on public.barbers for select to authenticated
  using (user_id = (select auth.uid()) or (select public.is_shop_owner(shop_id)));
create policy barbers_update on public.barbers for update to authenticated
  using (user_id = (select auth.uid()) or (select public.is_shop_owner(shop_id)))
  with check (user_id = (select auth.uid()) or (select public.is_shop_owner(shop_id)));
create policy barbers_owner_insert on public.barbers for insert to authenticated
  with check ((select public.is_shop_owner(shop_id)));

-- Bookings: clients create them only through create_booking(); barbers see their own,
-- the owner sees the whole shop. Status is the only column staff can change directly.
revoke all on public.bookings from anon;
revoke insert, update, delete on public.bookings from authenticated;
grant update (status) on public.bookings to authenticated;
create policy bookings_read on public.bookings for select to authenticated
  using (barber_id = (select public.current_barber_id()) or (select public.is_shop_owner(shop_id)));
create policy bookings_update_status on public.bookings for update to authenticated
  using (barber_id = (select public.current_barber_id()) or (select public.is_shop_owner(shop_id)))
  with check (barber_id = (select public.current_barber_id()) or (select public.is_shop_owner(shop_id)));

-- Rent sign-offs: read-only through the table; written through the functions below.
revoke all on public.rent_settlements from anon;
revoke insert, update, delete on public.rent_settlements from authenticated;
create policy rent_read on public.rent_settlements for select to authenticated
  using (barber_id = (select public.current_barber_id()) or (select public.is_shop_owner(shop_id)));

-- ── Public booking functions ──────────────────────────────────────────────
create function public.public_barbers(p_shop uuid)
returns table (id uuid, name text, specialty text, role text)
language sql stable security definer set search_path = '' as $$
  select b.id, b.name, b.specialty, b.role from public.barbers b
  where b.shop_id = p_shop and b.active
  order by (b.role = 'owner') desc, b.name
$$;

-- Busy intervals only (no client details) so the booking page can grey out taken slots.
create function public.busy_times(p_shop uuid, p_from timestamptz, p_to timestamptz)
returns table (barber_id uuid, starts_at timestamptz, ends_at timestamptz)
language plpgsql stable security definer set search_path = '' as $$
begin
  if p_to - p_from > interval '32 days' then raise exception 'range_too_long'; end if;
  return query
    select k.barber_id, k.starts_at, k.ends_at from public.bookings k
    where k.shop_id = p_shop and k.status in ('confirmed','done')
      and k.starts_at < p_to and k.ends_at > p_from;
end $$;

create function public.create_booking(
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
        client_name, client_phone, client_email, cut_notes, deposit_cents)
      values (p_shop, v_bid, p_service, p_starts_at, v_ends,
        trim(p_client_name), p_client_phone, nullif(trim(p_client_email), ''), nullif(trim(p_cut_notes), ''),
        v_shop.deposit_cents)
      returning id into v_id;
      return v_id;
    exception when exclusion_violation then
      null; -- that barber is taken, try the next one
    end;
  end loop;
  raise exception 'slot_taken';
end $$;

-- ── Staff functions ───────────────────────────────────────────────────────
-- Links a signed-in user to the barber row the owner created with their email.
create function public.claim_barber_profile() returns uuid
language plpgsql volatile security definer set search_path = '' as $$
declare v_id uuid;
begin
  select id into v_id from public.barbers where user_id = auth.uid();
  if v_id is not null then return v_id; end if;
  update public.barbers set user_id = auth.uid()
  where user_id is null and email is not null
    and lower(email) = (select lower(u.email) from auth.users u
                        where u.id = auth.uid() and u.email_confirmed_at is not null)
  returning id into v_id;
  return v_id;
end $$;

-- Until online deposits are live, the owner records deposits taken in person.
create function public.mark_deposit_paid(p_booking uuid, p_paid boolean default true) returns void
language plpgsql volatile security definer set search_path = '' as $$
declare v_shop uuid;
begin
  select shop_id into v_shop from public.bookings where id = p_booking;
  if v_shop is null or not public.is_shop_owner(v_shop) then raise exception 'not_allowed'; end if;
  update public.bookings set deposit_paid = p_paid where id = p_booking;
end $$;

-- Weekly statement. Owners see every renting barber; a barber sees only their own row.
create function public.rent_statement(p_shop uuid, p_week_start date)
returns table (barber_id uuid, barber_name text, bookings int, deposits_cents int, rent_cents int,
               balance_cents int, week_closed boolean, owner_marked_at timestamptz, barber_confirmed_at timestamptz)
language plpgsql stable security definer set search_path = '' as $$
declare v_shop public.shops%rowtype; v_from timestamptz; v_to timestamptz; v_owner boolean; v_me uuid;
begin
  if extract(isodow from p_week_start) <> 1 then raise exception 'week_must_start_monday'; end if;
  select * into v_shop from public.shops where id = p_shop;
  v_owner := public.is_shop_owner(p_shop);
  v_me := public.current_barber_id();
  if not v_owner and v_me is null then raise exception 'not_allowed'; end if;
  v_from := p_week_start::timestamp at time zone v_shop.timezone;
  v_to := (p_week_start + 7)::timestamp at time zone v_shop.timezone;
  return query
    select b.id, b.name,
      count(k.id)::int,
      coalesce(sum(k.deposit_cents), 0)::int,
      v_shop.weekly_rent_cents,
      (coalesce(sum(k.deposit_cents), 0) - v_shop.weekly_rent_cents)::int,
      now() >= v_to,
      s.owner_marked_at, s.barber_confirmed_at
    from public.barbers b
    left join public.bookings k on k.barber_id = b.id and k.deposit_paid
      and k.status <> 'cancelled' and k.starts_at >= v_from and k.starts_at < v_to
    left join public.rent_settlements s on s.barber_id = b.id and s.week_start = p_week_start
    where b.shop_id = p_shop and b.active and b.role = 'barber' and (v_owner or b.id = v_me)
    group by b.id, b.name, s.owner_marked_at, s.barber_confirmed_at
    order by b.name;
end $$;

create function public.mark_rent_settled(p_barber uuid, p_week_start date) returns void
language plpgsql volatile security definer set search_path = '' as $$
declare v_shop uuid; v_bal int; v_closed boolean;
begin
  select shop_id into v_shop from public.barbers where id = p_barber;
  if v_shop is null or not public.is_shop_owner(v_shop) then raise exception 'not_allowed'; end if;
  select r.balance_cents, r.week_closed into v_bal, v_closed
  from public.rent_statement(v_shop, p_week_start) r where r.barber_id = p_barber;
  if not coalesce(v_closed, false) then raise exception 'week_not_closed'; end if;
  insert into public.rent_settlements (shop_id, barber_id, week_start, balance_cents)
  values (v_shop, p_barber, p_week_start, v_bal)
  on conflict (barber_id, week_start) do nothing;
end $$;

create function public.confirm_rent_settled(p_week_start date) returns void
language plpgsql volatile security definer set search_path = '' as $$
declare v_me uuid := public.current_barber_id();
begin
  if v_me is null then raise exception 'not_allowed'; end if;
  update public.rent_settlements set barber_confirmed_at = now()
  where barber_id = v_me and week_start = p_week_start and barber_confirmed_at is null;
  if not found then raise exception 'nothing_to_confirm'; end if;
end $$;

-- Function access: booking functions are public; staff functions need a login.
revoke execute on all functions in schema public from public, anon;
grant execute on function public.public_barbers(uuid) to anon, authenticated;
grant execute on function public.busy_times(uuid, timestamptz, timestamptz) to anon, authenticated;
grant execute on function public.create_booking(uuid, uuid, uuid, timestamptz, text, text, text, text) to anon, authenticated;
grant execute on function public.current_barber_id(), public.is_shop_owner(uuid), public.claim_barber_profile(),
  public.mark_deposit_paid(uuid, boolean), public.rent_statement(uuid, date),
  public.mark_rent_settled(uuid, date), public.confirm_rent_settled(date) to authenticated;
