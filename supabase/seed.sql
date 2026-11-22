-- Shop data loaded into the fades4change project on 2026-11-22.
with s as (
  insert into public.shops (name, address) values
  ('Fades 4 Change Barbershop / Barberia', '311 Spartanburg Hwy, Suite A, Wellford, SC 29365')
  returning id
), sv as (
  insert into public.services (shop_id, name, minutes, price_cents, sort)
  select s.id, v.name, v.minutes, v.price, v.sort from s,
  (values ('Adult service',40,5000,1),('Child haircut',30,4000,2)) v(name,minutes,price,sort)
  returning 1
)
insert into public.barbers (shop_id, name, role)
select s.id, v.name, v.role from s,
(values ('Danny Orellana','owner'),('Cory Clippers','barber'),('Sasha Hamrick','barber'),('Brandon Lopez','barber')) v(name,role);
