-- Multi-location foundation: Organization -> Locations (shops) -> Barbers.
-- One login can own a whole organization and/or work as a barber in one or more shops.

-- ── Organizations and their owners ─────────────────────────────────────────
create table public.organizations (
  id uuid primary key default gen_random_uuid(),
  name text not null check (length(trim(name)) between 1 and 120),
  created_at timestamptz not null default now()
);
create table public.org_members (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations(id) on delete cascade,
  user_id uuid references auth.users(id) on delete set null,
  email text,
  role text not null default 'owner' check (role in ('owner')),
  created_at timestamptz not null default now()
);
create unique index org_members_org_user_idx on public.org_members(org_id, user_id) where user_id is not null;
create unique index org_members_org_email_idx on public.org_members(org_id, lower(email)) where email is not null;
create index org_members_user_idx on public.org_members(user_id);

-- ── Shops belong to an organization and get a web address (slug) ───────────
alter table public.shops add column org_id uuid references public.organizations(id);
alter table public.shops add column slug text;

with o as (insert into public.organizations (name) values ('Fades 4 Change') returning id)
update public.shops set org_id = (select id from o), slug = 'fades4change'
where id = '06efc15d-cee1-4954-8751-fb34d5452e35';

alter table public.shops alter column org_id set not null;
alter table public.shops add constraint shops_slug_format
  check (slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$' and length(slug) between 3 and 40);
alter table public.shops alter column slug set not null;
create unique index shops_slug_idx on public.shops(slug);
create index shops_org_idx on public.shops(org_id);

-- Danny owns the organization (same login as his owner chair).
insert into public.org_members (org_id, user_id, email)
select s.org_id, b.user_id, b.email from public.shops s
join public.barbers b on b.shop_id = s.id and b.role = 'owner'
where s.id = '06efc15d-cee1-4954-8751-fb34d5452e35';

-- ── A login can have a chair in more than one shop ─────────────────────────
alter table public.barbers drop constraint barbers_user_id_key;
create unique index barbers_shop_user_idx on public.barbers(shop_id, user_id) where user_id is not null;
create index barbers_user_idx on public.barbers(user_id);

-- ── Access helpers ─────────────────────────────────────────────────────────
create function private.is_org_owner(p_org uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.org_members where org_id = p_org and user_id = auth.uid())
$$;

-- Shop owner = owner chair in that shop, or owner of the organization it belongs to.
create or replace function private.is_shop_owner(p_shop uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.barbers
                 where user_id = auth.uid() and shop_id = p_shop and role = 'owner' and active)
      or exists (select 1 from public.shops s join public.org_members m on m.org_id = s.org_id
                 where s.id = p_shop and m.user_id = auth.uid())
$$;

-- Every chair this login has, in any shop.
create function private.my_barber_ids() returns setof uuid
language sql stable security definer set search_path = '' as $$
  select id from public.barbers where user_id = auth.uid() and active
$$;

grant execute on function private.is_org_owner(uuid), private.my_barber_ids() to authenticated;

-- Policies that assumed one chair per login.
drop policy bookings_read on public.bookings;
drop policy bookings_update_status on public.bookings;
drop policy rent_read on public.rent_settlements;
create policy bookings_read on public.bookings for select to authenticated
  using (barber_id in (select private.my_barber_ids()) or (select private.is_shop_owner(shop_id)));
create policy bookings_update_status on public.bookings for update to authenticated
  using (barber_id in (select private.my_barber_ids()) or (select private.is_shop_owner(shop_id)))
  with check (barber_id in (select private.my_barber_ids()) or (select private.is_shop_owner(shop_id)));
create policy rent_read on public.rent_settlements for select to authenticated
  using (barber_id in (select private.my_barber_ids()) or (select private.is_shop_owner(shop_id)));

alter table public.organizations enable row level security;
alter table public.org_members enable row level security;
revoke all on public.organizations, public.org_members from anon, authenticated;
grant select, insert, update, delete on public.organizations, public.org_members to service_role;
grant select on public.organizations, public.org_members to authenticated;
grant update (name) on public.organizations to authenticated;
create policy orgs_read on public.organizations for select to authenticated
  using ((select private.is_org_owner(id)));
create policy orgs_owner_update on public.organizations for update to authenticated
  using ((select private.is_org_owner(id))) with check ((select private.is_org_owner(id)));
create policy org_members_read on public.org_members for select to authenticated
  using ((select private.is_org_owner(org_id)));

-- ── Functions that assumed one chair per login ─────────────────────────────
create or replace function public.rent_statement(p_shop uuid, p_week_start date)
returns table (barber_id uuid, barber_name text, bookings int, deposits_cents int, rent_cents int,
               balance_cents int, week_closed boolean, owner_marked_at timestamptz, barber_confirmed_at timestamptz)
language plpgsql stable security definer set search_path = '' as $$
declare v_shop public.shops%rowtype; v_from timestamptz; v_to timestamptz; v_owner boolean; v_me uuid;
begin
  if extract(isodow from p_week_start) <> 1 then raise exception 'week_must_start_monday'; end if;
  select * into v_shop from public.shops where id = p_shop;
  v_owner := private.is_shop_owner(p_shop);
  select id into v_me from public.barbers where user_id = auth.uid() and shop_id = p_shop and active;
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

drop function public.confirm_rent_settled(date);
create function public.confirm_rent_settled(p_shop uuid, p_week_start date) returns void
language plpgsql volatile security definer set search_path = '' as $$
declare v_me uuid;
begin
  select id into v_me from public.barbers where user_id = auth.uid() and shop_id = p_shop and active;
  if v_me is null then raise exception 'not_allowed'; end if;
  update public.rent_settlements set barber_confirmed_at = now()
  where barber_id = v_me and week_start = p_week_start and barber_confirmed_at is null;
  if not found then raise exception 'nothing_to_confirm'; end if;
end $$;

create or replace function public.staff_add_booking(
  p_barber uuid, p_service uuid, p_starts_at timestamptz, p_client_name text, p_source text,
  p_client_phone text default null, p_cut_notes text default null, p_minutes int default null)
returns uuid
language plpgsql volatile security definer set search_path = '' as $$
declare v_b public.barbers%rowtype; v_svc public.services%rowtype; v_min int; v_id uuid;
begin
  select * into v_b from public.barbers where id = p_barber and active;
  if not found then raise exception 'barber_not_found'; end if;
  if not (private.is_shop_owner(v_b.shop_id) or v_b.user_id = auth.uid()) then
    raise exception 'not_allowed';
  end if;
  if p_source not in ('booksy', 'walkin') then raise exception 'bad_source'; end if;
  select * into v_svc from public.services where id = p_service and shop_id = v_b.shop_id;
  if not found then raise exception 'service_not_found'; end if;
  if length(trim(coalesce(p_client_name, ''))) = 0 then raise exception 'name_required'; end if;
  v_min := coalesce(p_minutes, v_svc.minutes);
  if v_min not between 5 and 480 then raise exception 'bad_length'; end if;
  begin
    insert into public.bookings (shop_id, barber_id, service_id, starts_at, ends_at, client_name,
      client_phone, cut_notes, deposit_cents, source)
    values (v_b.shop_id, p_barber, p_service, p_starts_at, p_starts_at + make_interval(mins => v_min),
      trim(p_client_name), nullif(trim(p_client_phone), ''), nullif(trim(p_cut_notes), ''), 0, p_source)
    returning id into v_id;
  exception when exclusion_violation then
    raise exception 'slot_taken';
  end;
  return v_id;
end $$;

-- Links a confirmed login to every chair and organization that lists its email.
drop function public.claim_barber_profile();
create function public.claim_access() returns int
language plpgsql volatile security definer set search_path = '' as $$
declare v_email text; n int := 0; m int;
begin
  select lower(u.email) into v_email from auth.users u where u.id = auth.uid() and u.email_confirmed_at is not null;
  if v_email is null then return 0; end if;
  update public.barbers set user_id = auth.uid()
  where user_id is null and email is not null and lower(email) = v_email
    and not exists (select 1 from public.barbers b2 where b2.shop_id = barbers.shop_id and b2.user_id = auth.uid());
  get diagnostics m = row_count; n := n + m;
  update public.org_members set user_id = auth.uid()
  where user_id is null and email is not null and lower(email) = v_email;
  get diagnostics m = row_count; n := n + m;
  return n;
end $$;

-- Every shop this login can open, and its role there.
create function public.my_access()
returns table (shop_id uuid, shop_name text, slug text, org_id uuid, org_name text, role text, barber_id uuid)
language sql stable security definer set search_path = '' as $$
  select s.id, s.name, s.slug, o.id, o.name,
    case when exists (select 1 from public.org_members m where m.org_id = s.org_id and m.user_id = auth.uid()) then 'org_owner'
         when b.role = 'owner' then 'owner' else 'barber' end,
    b.id
  from public.shops s
  join public.organizations o on o.id = s.org_id
  left join public.barbers b on b.shop_id = s.id and b.user_id = auth.uid() and b.active
  where b.id is not null
     or exists (select 1 from public.org_members m where m.org_id = s.org_id and m.user_id = auth.uid())
  order by o.name, s.name
$$;

-- Organization owner adds a location, copying hours, prices and services from an existing shop.
create function public.create_location(p_copy_from uuid, p_name text, p_address text, p_slug text)
returns uuid
language plpgsql volatile security definer set search_path = '' as $$
declare v_src public.shops%rowtype; v_id uuid;
begin
  select * into v_src from public.shops where id = p_copy_from;
  if not found or not private.is_org_owner(v_src.org_id) then raise exception 'not_allowed'; end if;
  if length(trim(coalesce(p_name, ''))) = 0 then raise exception 'name_required'; end if;
  if exists (select 1 from public.shops where slug = lower(trim(p_slug))) then raise exception 'slug_taken'; end if;
  insert into public.shops (org_id, name, address, slug, timezone, open_minute, close_minute, slot_minutes,
    deposit_cents, weekly_rent_cents, appointment_only_dows)
  values (v_src.org_id, trim(p_name), nullif(trim(p_address), ''), lower(trim(p_slug)), v_src.timezone,
    v_src.open_minute, v_src.close_minute, v_src.slot_minutes, v_src.deposit_cents, v_src.weekly_rent_cents,
    v_src.appointment_only_dows)
  returning id into v_id;
  insert into public.services (shop_id, name, minutes, price_cents, sort, active)
  select v_id, name, minutes, price_cents, sort, active from public.services where shop_id = p_copy_from;
  insert into public.kiosk_settings (shop_id) values (v_id);
  return v_id;
exception when check_violation then
  raise exception 'bad_slug';
end $$;

revoke execute on function public.confirm_rent_settled(uuid, date), public.claim_access(),
  public.my_access(), public.create_location(uuid, text, text, text) from public, anon;
grant execute on function public.confirm_rent_settled(uuid, date), public.claim_access(),
  public.my_access(), public.create_location(uuid, text, text, text) to authenticated;
