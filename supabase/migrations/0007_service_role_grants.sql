-- This project does not grant table access by default, including to the server-side role
-- the calendar and reminders functions use.
grant usage on schema public to service_role;
grant select, insert, update, delete on all tables in schema public to service_role;
alter default privileges in schema public grant select, insert, update, delete on tables to service_role;
