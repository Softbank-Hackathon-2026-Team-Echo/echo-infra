-- Run as the WAS database owner AFTER the WAS evidence migration.
-- Separate LOGIN is provisioned out of band; no password in SQL/history.
-- This role is a trusted evidence writer, not an app executor or schema owner.
DO $$ BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'echo_security_collector') THEN
    CREATE ROLE echo_security_collector NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE;
  END IF;
END $$;
GRANT USAGE ON SCHEMA public TO echo_security_collector;
GRANT SELECT ON public.environments, public.findings TO echo_security_collector;
-- PostgreSQL SELECT FOR UPDATE needs UPDATE on at least one column.
-- Only the timestamp is permitted, never config/secret_ref/identity/deletion.
GRANT UPDATE (updated_at) ON public.environments TO echo_security_collector;
GRANT INSERT ON public.findings TO echo_security_collector;
GRANT UPDATE (superseded_at, updated_at) ON public.findings TO echo_security_collector;
-- Do not grant this role to the application login; give it to a new dedicated LOGIN.
-- No jobs, deploys, app secrets, schema creation, DELETE, or existing finding verdict updates.
