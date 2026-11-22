-- Save whatever the owner entered; only switch online deposits on when all three keys are present.
-- Returns whether deposits are on after saving.
drop function public.set_payment_settings(uuid, text, text, text, text, boolean);
create function public.set_payment_settings(p_shop uuid, p_environment text, p_merchant_id text,
  p_private_token text, p_webhook_secret text, p_enabled boolean)
returns boolean language plpgsql volatile security definer set search_path = '' as $$
declare v_on boolean;
begin
  if not private.is_shop_owner(p_shop) then raise exception 'not_allowed'; end if;
  if p_environment not in ('sandbox', 'production') then raise exception 'bad_environment'; end if;
  insert into public.payment_settings (shop_id) values (p_shop) on conflict (shop_id) do nothing;
  update public.payment_settings set
    environment = p_environment,
    merchant_id = coalesce(nullif(trim(p_merchant_id), ''), merchant_id),
    private_token = coalesce(nullif(trim(p_private_token), ''), private_token),
    webhook_secret = coalesce(nullif(trim(p_webhook_secret), ''), webhook_secret),
    updated_at = now()
  where shop_id = p_shop;
  update public.payment_settings
    set enabled = p_enabled and merchant_id is not null and private_token is not null and webhook_secret is not null
  where shop_id = p_shop
  returning enabled into v_on;
  return v_on;
end $$;
revoke execute on function public.set_payment_settings(uuid, text, text, text, text, boolean) from public, anon;
grant execute on function public.set_payment_settings(uuid, text, text, text, text, boolean) to authenticated;
