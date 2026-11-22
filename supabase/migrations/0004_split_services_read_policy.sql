-- Signed-out visitors cannot call private helpers, so they get their own simple policy.
drop policy services_read on public.services;
create policy services_read_public on public.services for select to anon using (active);
create policy services_read_staff on public.services for select to authenticated
  using (active or (select private.is_shop_owner(shop_id)));
