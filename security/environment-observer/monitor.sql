-- Run once as DB owner after review. No login/password is created here.
-- Map session targets to the actual DB users/application names before applying.
BEGIN;
CREATE SCHEMA IF NOT EXISTS echo_security;
REVOKE ALL ON SCHEMA echo_security FROM PUBLIC;
CREATE TABLE IF NOT EXISTS echo_security.transport_targets (
    target text PRIMARY KEY,
    database_name name NOT NULL,
    user_name name NOT NULL,
    application_name text NOT NULL
);
REVOKE ALL ON echo_security.transport_targets FROM PUBLIC;
CREATE OR REPLACE FUNCTION echo_security.transport_sessions()
RETURNS TABLE(target text, ssl boolean, version text, session_count bigint)
LANGUAGE sql SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
    SELECT t.target, s.ssl, s.version, count(*)::bigint
    FROM echo_security.transport_targets AS t
    JOIN pg_catalog.pg_stat_activity AS a
      ON a.datname = t.database_name
     AND a.usename = t.user_name
     AND a.application_name = t.application_name
    JOIN pg_catalog.pg_stat_ssl AS s ON s.pid = a.pid
    WHERE a.pid <> pg_catalog.pg_backend_pid()
    GROUP BY t.target, s.ssl, s.version
$$;
REVOKE ALL ON FUNCTION echo_security.transport_sessions() FROM PUBLIC;
-- A separately provisioned LOGIN role receives only these two grants:
-- GRANT USAGE ON SCHEMA echo_security TO echo_transport_monitor;
-- GRANT EXECUTE ON FUNCTION echo_security.transport_sessions() TO echo_transport_monitor;
-- Do not grant pg_monitor / pg_read_all_stats / table SELECT / write / replication.
COMMIT;
