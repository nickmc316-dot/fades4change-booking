-- Multi-location foundation: Organization -> Locations (shops) -> Barbers.
-- Additive only: nothing is dropped. One login still holds at most one barber chair; an organization
-- owner can manage every shop in the organization without needing a chair in each.

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

alter table public.organizations enable row level security;
alter table public.org_members enable row level security;
revoke all on public.organizations, public.org_members from anon, authenticated;
grant select, insert, update, delete on public.organizations, public.org_members to service_role;
grant select on public.organizations, public.org_members to authenticated;
grant update (name) on public.organizations to authenticated;

-- ── Shops belong to an organization and get a web address (slug) ───────────
alter table public.shops add column org_id uuid references public.organizations(id);
alter table public.shops add column slug text;

with o as (insert into public.organizations (name) values ('Fades 4 Change') returning id)
update public.shops set org_id = (select id from o), slug = 'fades4change'
where id = '06efc15d-cee1-4954-8751-fb34d5452e35';

alter table public.shops alter column org_id set not null;
alter table public.shops alter column slug set not null;
alter table public.shops add constraint shops_slug_format
  check (slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$' and length(slug) between 3 and 40);
create unique index shops_slug_idx on public.shops(slug);
create index shops_org_idx on public.shops(org_id);

-- Danny owns the organization (same login as his owner chair).
insert into public.org_members (org_id, user_id, email)
select s.org_id, b.user_id, b.email from public.shops s
join public.barbers b on b.shop_id = s.id and b.role = 'owner'
where s.id = '06efc15d-cee1-4954-8751-fb34d5452e35';

-- ── Access ─────────────────────────────────────────────────────────────────
create function private.is_org_owner(p_org uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.org_members where org_id = p_org and user_id = auth.uid())
$$;
grant execute on function private.is_org_owner(uuid) to authenticated;

-- Shop owner = owner chair in that shop, or owner of the organization it belongs to.
-- (Every existing policy and function checks this, so org owners get access everywhere at once.)
create or replace function private.is_shop_owner(p_shop uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.barbers
                 where user_id = auth.uid() and shop_id = p_shop and role = 'owner' and active)
      or exists (select 1 from public.shops s join public.org_members m on m.org_id = s.org_id
                 where s.id = p_shop and m.user_id = auth.uid())
$$;

create policy orgs_read on public.organizations for select to authenticated
  using ((select private.is_org_owner(id)));
create policy orgs_owner_update on public.organizations for update to authenticated
  using ((select private.is_org_owner(id))) with check ((select private.is_org_owner(id)));
create policy org_members_read on public.org_members for select to authenticated
  using ((select private.is_org_owner(org_id)));

-- Links a confirmed login to the chair and organizations that list its email.
create function public.claim_access() returns int
language plpgsql volatile security definer set search_path = '' as $$
declare v_email text; n int := 0; m int;
begin
  select lower(u.email) into v_email from auth.users u where u.id = auth.uid() and u.email_confirmed_at is not null;
  if v_email is null then return 0; end if;
  if not exists (select 1 from public.barbers where user_id = auth.uid()) then
    update public.barbers set user_id = auth.uid()
    where id = (select id from public.barbers where user_id is null and email is not null and lower(email) = v_email
                order by created_at limit 1);
    get diagnostics m = row_count; n := n + m;
  end if;
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
declare v_src public.shops%rowtype; v_id uuid; v_slug text := lower(trim(coalesce(p_slug, '')));
begin
  select * into v_src from public.shops where id = p_copy_from;
  if not found or not private.is_org_owner(v_src.org_id) then raise exception 'not_allowed'; end if;
  if length(trim(coalesce(p_name, ''))) = 0 then raise exception 'name_required'; end if;
  if v_slug !~ '^[a-z0-9]+(-[a-z0-9]+)*$' or length(v_slug) not between 3 and 40 then raise exception 'bad_slug'; end if;
  if exists (select 1 from public.shops where slug = v_slug) then raise exception 'slug_taken'; end if;
  insert into public.shops (org_id, name, address, slug, timezone, open_minute, close_minute, slot_minutes,
    deposit_cents, weekly_rent_cents, appointment_only_dows)
  values (v_src.org_id, trim(p_name), nullif(trim(p_address), ''), v_slug, v_src.timezone,
    v_src.open_minute, v_src.close_minute, v_src.slot_minutes, v_src.deposit_cents, v_src.weekly_rent_cents,
    v_src.appointment_only_dows)
  returning id into v_id;
  insert into public.services (shop_id, name, minutes, price_cents, sort, active)
  select v_id, name, minutes, price_cents, sort, active from public.services where shop_id = p_copy_from;
  insert into public.kiosk_settings (shop_id) values (v_id);
  return v_id;
end $$;

revoke execute on function public.claim_access(), public.my_access(), public.create_location(uuid, text, text, text) from public, anon;
grant execute on function public.claim_access(), public.my_access(), public.create_location(uuid, text, text, text) to authenticated;
