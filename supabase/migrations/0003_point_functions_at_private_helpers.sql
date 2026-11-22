-- Re-create the functions whose bodies call the moved helpers by name.
do $$
declare r record; def text;
begin
  for r in select p.oid from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public'
             and (p.prosrc like '%public.is_shop_owner%' or p.prosrc like '%public.current_barber_id%')
  loop
    def := pg_get_functiondef(r.oid);
    def := replace(replace(def, 'public.is_shop_owner', 'private.is_shop_owner'),
                   'public.current_barber_id', 'private.current_barber_id');
    execute def;
  end loop;
end $$;
