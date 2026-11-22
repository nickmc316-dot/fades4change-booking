-- This project does not grant table access to API roles by default: grant it explicitly.
grant usage on schema public to anon, authenticated;
grant select on public.shops, public.services to anon, authenticated;
grant select on public.barbers, public.bookings, public.rent_settlements to authenticated;
grant update (name, address, timezone, open_minute, close_minute, slot_minutes, deposit_cents, weekly_rent_cents, appointment_only_dows) on public.shops to authenticated;
grant insert (shop_id, name, minutes, price_cents, sort, active) on public.services to authenticated;
grant update (name, minutes, price_cents, sort, active) on public.services to authenticated;

-- Policy helpers live outside the exposed API schema.
create schema if not exists private;
revoke all on schema private from public, anon;
grant usage on schema private to authenticated;
alter function public.current_barber_id() set schema private;
alter function public.is_shop_owner(uuid) set schema private;
grant execute on function private.current_barber_id(), private.is_shop_owner(uuid) to authenticated;
