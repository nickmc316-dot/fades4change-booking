-- The owner adds each barber's login email from the dashboard (row policy limits who can edit which row).
grant update (email) on public.barbers to authenticated;
