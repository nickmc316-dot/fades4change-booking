-- Front-door tablet for walk-ins. Check-ins need the shop's kiosk key, which only the owner can see,
-- so the public internet can't fill the schedule with fake walk-ins.
create table public.kiosk_settings (
  shop_id uuid primary key references public.shops(id) on delete cascade,
  token text not null default encode(extensions.gen_random_bytes(18), 'hex'),
  updated_at timestamptz not null default now()
);
alter table public.kiosk_settings enable row level security;
revoke all on public.kiosk_settings from anon, authenticated;
grant select, insert, update, delete on public.kiosk_settings to service_role;
insert into public.kiosk_settings (shop_id) select id from public.shops;

-- Owner reads (or replaces) the kiosk key.
create function public.get_kiosk_token(p_shop uuid, p_reset boolean default false) returns text
language plpgsql volatile security definer set search_path = '' as $$
declare v text;
begin
  if not private.is_shop_owner(p_shop) then raise exception 'not_allowed'; end if;
  insert into public.kiosk_settings (shop_id) values (p_shop) on conflict (shop_id) do nothing;
  if p_reset then
    update public.kiosk_settings set token = encode(extensions.gen_random_bytes(18), 'hex'), updated_at = now()
    where shop_id = p_shop;
  end if;
  select token into v from public.kiosk_settings where shop_id = p_shop;
  return v;
end $$;

-- Is this device's saved key still valid?
create function public.kiosk_ok(p_shop uuid, p_token text) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.kiosk_settings where shop_id = p_shop and token = p_token)
$$;

-- Walk-in check-in: today only, no deposit, name only.
create function public.create_walkin(p_shop uuid, p_token text, p_service uuid, p_barber uuid,
  p_starts_at timestamptz, p_client_name text)
returns table (booking_id uuid, barber_name text)
language plpgsql volatile security definer set search_path = '' as $$
declare
  v_shop public.shops%rowtype; v_svc public.services%rowtype;
  v_ends timestamptz; v_local timestamp; v_end_local timestamp; v_start_min int; v_end_min int;
  v_id uuid; v_bid uuid;
begin
  if not public.kiosk_ok(p_shop, p_token) then raise exception 'kiosk_not_set_up'; end if;
  select * into v_shop from public.shops where id = p_shop;
  select * into v_svc from public.services where id = p_service and shop_id = p_shop and active;
  if not found then raise exception 'service_not_found'; end if;
  if length(trim(coalesce(p_client_name, ''))) = 0 then raise exception 'name_required'; end if;

  v_ends := p_starts_at + make_interval(mins => v_svc.minutes);
  v_local := p_starts_at at time zone v_shop.timezone;
  v_end_local := v_ends at time zone v_shop.timezone;
  if v_local::date <> (now() at time zone v_shop.timezone)::date then raise exception 'today_only'; end if;
  if p_starts_at < now() - interval '5 minutes' then raise exception 'too_soon'; end if;
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
      insert into public.bookings (shop_id, barber_id, service_id, starts_at, ends_at, client_name, deposit_cents, source)
      values (p_shop, v_bid, p_service, p_starts_at, v_ends, trim(p_client_name), 0, 'walkin')
      returning id into v_id;
      return query select v_id, (select name from public.barbers where id = v_bid);
      return;
    exception when exclusion_violation then
      null;
    end;
  end loop;
  raise exception 'slot_taken';
end $$;

revoke execute on function public.get_kiosk_token(uuid, boolean), public.kiosk_ok(uuid, text),
  public.create_walkin(uuid, text, uuid, uuid, timestamptz, text) from public, anon;
grant execute on function public.get_kiosk_token(uuid, boolean) to authenticated;
grant execute on function public.kiosk_ok(uuid, text), public.create_walkin(uuid, text, uuid, uuid, timestamptz, text)
  to anon, authenticated;
