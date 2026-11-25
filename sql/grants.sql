-- Privileges for the backup role. Run once as a superuser.
-- The docker-compose Postgres user is already a superuser and does not need this.
-- Change "app" if PGDATABASE is different.

CREATE ROLE infrawatch WITH LOGIN;
-- Set the password out of band: \password infrawatch
-- Or use peer/ident and a local socket instead of a password.

ALTER ROLE infrawatch CREATEDB;
GRANT pg_read_all_data TO infrawatch;
GRANT pg_monitor TO infrawatch;

-- Restore tests connect to the maintenance database to CREATE/DROP the scratch db.
GRANT CONNECT ON DATABASE postgres TO infrawatch;
GRANT CONNECT ON DATABASE app TO infrawatch;
