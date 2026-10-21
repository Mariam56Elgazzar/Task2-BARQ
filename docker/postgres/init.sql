\set ON_ERROR_STOP on
\getenv app_password DB_APP_PASSWORD

BEGIN;

CREATE ROLE notes_app
    LOGIN
    NOSUPERUSER
    NOCREATEDB
    NOCREATEROLE
    NOREPLICATION
    PASSWORD :'app_password';

\unset app_password

REVOKE ALL ON DATABASE notes FROM PUBLIC;
GRANT CONNECT ON DATABASE notes TO notes_app;

REVOKE ALL ON SCHEMA public FROM PUBLIC;
GRANT USAGE ON SCHEMA public TO notes_app;

\i /opt/notes/schema.sql

GRANT SELECT, INSERT, UPDATE, DELETE
    ON TABLE public.notes TO notes_app;

GRANT USAGE
    ON SEQUENCE public.notes_id_seq TO notes_app;

COMMIT;
