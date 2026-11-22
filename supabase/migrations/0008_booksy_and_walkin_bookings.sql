-- Appointments that come from Booksy or walk-ins, added by staff. They block the same time on the
-- booking page (the no_double_booking constraint covers every source).
alter table public.bookings add column source text not null default 'app'
  check (source in ('app', 'booksy', 'walkin'));
alter table public.bookings add column external_ref text;
alter table public.bookings alter column client_phone drop not null;
alter table public.bookings add constraint app_bookings_need_phone check (source <> 'app' or client_phone is not null);
create unique index bookings_external_ref_idx on public.bookings(shop_id, external_ref) where external_ref is not null;

create function public.staff_add_booking(
  p_barber uuid, p_service uuid, p_starts_at timestamptz, p_client_name text, p_source text,
  p_client_phone text default null, p_cut_notes text default null, p_minutes int default null)
returns uuid
language plpgsql volatile security definer set search_path = '' as $$
declare v_b public.barbers%rowtype; v_svc public.services%rowtype; v_min int; v_id uuid;
begin
  select * into v_b from public.barbers where id = p_barber and active;
  if not found then raise exception 'barber_not_found'; end if;
  if not (private.is_shop_owner(v_b.shop_id) or private.current_barber_id() = p_barber) then
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

revoke execute on function public.staff_add_booking(uuid, uuid, timestamptz, text, text, text, text, int) from public, anon;
grant execute on function public.staff_add_booking(uuid, uuid, timestamptz, text, text, text, text, int) to authenticated;
