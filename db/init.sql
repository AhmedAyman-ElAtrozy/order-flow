-- OrderFlow database bootstrap.
--
-- Runs ONCE, by the postgres image entrypoint, on an EMPTY data volume, as the
-- admin superuser, connected to database "orderflow" (POSTGRES_DB).
-- Changing a password in .env later has no effect until: .\scripts\dev.ps1 reset
--
-- One database, four schemas, four login roles. Each service role:
--   * owns exactly one schema (so it can create its own tables/migrations),
--   * has NO usage on any other schema (rule: no service reads another's tables),
--   * gets search_path = its own schema, so unqualified table names resolve there.
--
-- Passwords are NOT in this file. psql's \getenv reads them from the container
-- environment (passed by docker-compose.yml from .env). :'var' interpolates
-- them as a correctly quoted SQL literal.

\set ON_ERROR_STOP on

\getenv identity_pw  IDENTITY_DB_PASSWORD
\getenv orders_pw    ORDERS_DB_PASSWORD
\getenv inventory_pw INVENTORY_DB_PASSWORD
\getenv payments_pw  PAYMENTS_DB_PASSWORD

-- Fail loudly if any password is missing, instead of creating a role with a
-- broken or empty password.
\if :{?identity_pw}
\else
  DO $$ BEGIN RAISE EXCEPTION 'IDENTITY_DB_PASSWORD is not set'; END $$;
\endif
\if :{?orders_pw}
\else
  DO $$ BEGIN RAISE EXCEPTION 'ORDERS_DB_PASSWORD is not set'; END $$;
\endif
\if :{?inventory_pw}
\else
  DO $$ BEGIN RAISE EXCEPTION 'INVENTORY_DB_PASSWORD is not set'; END $$;
\endif
\if :{?payments_pw}
\else
  DO $$ BEGIN RAISE EXCEPTION 'PAYMENTS_DB_PASSWORD is not set'; END $$;
\endif

BEGIN;

-- 1. Lock down defaults. By default every role (PUBLIC) may CONNECT to any
--    database, create TEMP tables, and use schema "public". Remove all of it so
--    access is only what we grant explicitly below.
REVOKE ALL ON DATABASE orderflow FROM PUBLIC;
REVOKE ALL ON DATABASE postgres  FROM PUBLIC;
REVOKE ALL ON SCHEMA public FROM PUBLIC;

-- 2. One role per service. NOINHERIT + no special attributes: least privilege.
CREATE ROLE identity_svc  LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT PASSWORD :'identity_pw';
CREATE ROLE orders_svc    LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT PASSWORD :'orders_pw';
CREATE ROLE inventory_svc LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT PASSWORD :'inventory_pw';
CREATE ROLE payments_svc  LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT PASSWORD :'payments_pw';

GRANT CONNECT ON DATABASE orderflow TO identity_svc, orders_svc, inventory_svc, payments_svc;

-- 3. One schema per service, owned by that service's role. The owner has full
--    rights inside it; nobody else gets USAGE, so cross-schema reads fail with
--    "permission denied for schema".
CREATE SCHEMA identity  AUTHORIZATION identity_svc;
CREATE SCHEMA orders    AUTHORIZATION orders_svc;
CREATE SCHEMA inventory AUTHORIZATION inventory_svc;
CREATE SCHEMA payments  AUTHORIZATION payments_svc;

-- 4. Unqualified names resolve to the service's own schema only.
ALTER ROLE identity_svc  IN DATABASE orderflow SET search_path = identity;
ALTER ROLE orders_svc    IN DATABASE orderflow SET search_path = orders;
ALTER ROLE inventory_svc IN DATABASE orderflow SET search_path = inventory;
ALTER ROLE payments_svc  IN DATABASE orderflow SET search_path = payments;

COMMIT;
