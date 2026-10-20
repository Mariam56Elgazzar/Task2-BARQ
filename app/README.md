# Notes API

A small FastAPI service that stores notes in PostgreSQL using psycopg 3.
The service has no in-memory data store and does not need AWS to run its tests.
Run all commands below from the repository root. Use CPython 3.11.

## Install and test

PowerShell:

```powershell
python -m venv .venv
.venv/Scripts/python.exe -m pip install -r app/requirements-dev.txt
.venv/Scripts/python.exe -m pytest app/tests -q -s
```

Linux/WSL:

```bash
python3.11 -m venv .venv
.venv/bin/python -m pip install -r app/requirements-dev.txt
.venv/bin/python -m pytest app/tests -q -s
```

Docker Engine must be running with permission to create containers. The integration
fixture starts `postgres:17.11-bookworm` with generated passwords and a random
loopback-only port. It creates separate schema-owner and application roles,
exercises real PostgreSQL, and removes its own container and anonymous volume
on completion. The application role has no superuser, database-creation,
role-creation or schema-creation privileges. Tests never use your configured
`DB_*` environment or an existing database. Allow an initial image download.
Do not use pytest `--showlocals`, which can expose test credentials on failures.

For configuration/retry tests without Docker:

```powershell
.venv/Scripts/python.exe -m pytest app/tests/test_unit.py -q
```

The complete suite checks CRUD using independent SQL connections, SQL-like text
and Unicode, validation, missing schema, incorrect passwords, bounded startup
retries, an actual DB stop/start, startup during a DB outage, and a real Uvicorn
HTTP request. A pre-existing note must survive the DB restart. This is local
application proof, not evidence of EBS mounts, container recreation, backups,
restoration, host reboot recovery or AWS network isolation.

`requirements.txt` pins runtime dependencies; `requirements-dev.txt` pins the
test environment including the same runtime versions. Install only the runtime
file in a production image. To deliberately update dependencies with uv:

```bash
uv pip compile app/requirements.in --python-version 3.11 --universal --no-header -o app/requirements.txt
uv pip compile app/requirements-dev.in --python-version 3.11 --universal --no-header -o app/requirements-dev.txt
```

Rerun the full suite after updating either file.

## Configuration and schema setup

| Variable | Meaning | Default |
| --- | --- | --- |
| `DB_HOST` | Single PostgreSQL hostname or IP | Required |
| `DB_PORT` | PostgreSQL listener port | `5432` |
| `DB_NAME` | Database name, normally `notes` | Required |
| `DB_USER` | Login role, normally `notes_app` | Required |
| `DB_PASSWORD` | Password for that login | Required; no default |

`.env.example` documents the variables. The app does not automatically load an
environment file. Supply credentials through a protected deployment environment
or your local shell; do not place them in command arguments or tracked files.
Settings errors name the invalid/missing field without echoing its value.
Passwords are passed as connection keyword arguments, so quotes, `@`, `/`, `?`
and other connection-string punctuation do not need URL escaping.

Provision the database and a separate schema-owner login before starting the app.
As a database administrator, grant that owner `USAGE, CREATE` on the `public`
schema and ensure the application role has `USAGE` only. Revoke `CREATE` from
`PUBLIC` if it is present. Both roles need `CONNECT` on the database. Use the
owner's `DB_*` credentials for this explicit setup command:

```powershell
.venv/Scripts/python.exe -m app.init_db
```

It executes `schema.sql` in one transaction. Repeating it preserves the table
and its records. It does not upgrade an incompatible existing schema; introduce
an explicit migration when changing the schema later. The app and health probes
never create tables. After initialization, the table owner grants:

```sql
GRANT SELECT, INSERT, UPDATE, DELETE ON public.notes TO notes_app;
GRANT USAGE ON SEQUENCE public.notes_id_seq TO notes_app;
```

Switch the app environment back to `notes_app` credentials before launch.
The later database provisioning automation must implement this bootstrap/grant
contract and securely supply credentials. Administrator credentials must never
be used by the running API.

## Run and call the API

With the five database variables set, start the server for local use:

```powershell
.venv/Scripts/python.exe -m uvicorn app.main:create_app --factory --host 127.0.0.1 --port 8000
```

On Linux, use `.venv/bin/python`. In the future container, listen on `0.0.0.0:8000`
so Nginx can reach `app:8000` on the shared Docker network. The deployment must
publish Nginx port 80 only and set `DB_HOST` to the database host's private IP.
There is no Dockerfile, Compose stack or deployment automation in this API change.

Open `http://127.0.0.1:8000/docs` for the generated API reference, or use:

```powershell
Invoke-RestMethod http://127.0.0.1:8000/healthz
Invoke-RestMethod http://127.0.0.1:8000/readyz
$note = Invoke-RestMethod http://127.0.0.1:8000/api/notes -Method Post -ContentType application/json -Body '{"title":"Demo","content":"Stored in PostgreSQL"}'
Invoke-RestMethod "http://127.0.0.1:8000/api/notes/$($note.id)"
Invoke-RestMethod "http://127.0.0.1:8000/api/notes/$($note.id)" -Method Put -ContentType application/json -Body '{"title":"Demo updated","content":"New content"}'
Invoke-RestMethod "http://127.0.0.1:8000/api/notes/$($note.id)" -Method Delete
```

| Request | Successful response |
| --- | --- |
| `GET /healthz` | `200 {"status":"ok"}`; process health, no DB query |
| `GET /readyz` | `200 {"status":"ready"}`; authenticated table query |
| `POST /api/notes` | `201` note and `Location` header |
| `GET /api/notes?limit=50&offset=0` | `200` array, ordered by ID; limit 1–100 |
| `GET /api/notes/{id}` | `200` note |
| `PUT /api/notes/{id}` | `200` note; replace both title and content |
| `DELETE /api/notes/{id}` | `204`, no response body |

A note has `id`, `title`, `content`, and timezone-aware `created_at`. The title
allows 1–200 characters; content allows 1–10,000. Whitespace-only text, NUL
characters, extra fields and non-string text are rejected. Existing whitespace
and Unicode are preserved. IDs are positive signed 64-bit integers.
Invalid requests return `422`; absent notes return `404`; database failures return
a generic `503` without raw SQL, host details, credentials or rejected input.

## Explain the implementation

“FastAPI validates the request. Psycopg passes the text separately from the SQL,
so a note containing SQL is stored as text. PostgreSQL generates the ID and
timestamp. The connection context commits before the API returns the row, or
rolls back if the operation fails. Each request opens a fresh connection, so a
database restart does not leave the app using a stale connection.”

“Health says the API process can respond. Readiness logs into PostgreSQL using
the app credentials and queries the expected table. A running database with the
wrong password, missing table or missing SELECT grant is not ready.”

The app makes four startup readiness attempts with 0.5, 1 and 2 second backoff.
Connections use a 3-second connect timeout, a 3-second SQL statement timeout,
and a 2-second lock timeout. OS DNS/network behaviour can add time; these are
not a hard end-to-end request deadline. After unsuccessful startup probes, the
process serves health while readiness and data requests return `503`. Later
requests reconnect automatically. Writes are never replayed: after a lost commit
acknowledgment the client cannot know whether the write committed. A retried POST
can duplicate data; this small service does not implement idempotency keys.

## Troubleshoot and limitations

| Symptom | Check |
| --- | --- |
| Process exits before listening | Required variable names and valid `DB_PORT`; do not print passwords |
| Health 200, readiness 503 | DB container/listener, private IP, routing/SG, password and `pg_hba.conf`, then schema/SELECT grants |
| Readiness 200, writes 503 | Table INSERT/UPDATE/DELETE and sequence USAGE grants; locks; DB disk space/read-only state |
| Note 404 | ID and selected database; rows are not recreated by app startup |
| Docker tests cannot start | Docker daemon/access, image pull access, and available disk space |

Readiness verifies authenticated reads, not every write permission. Use a create/read
smoke test after deployment. Logs report failure classes without raw database
exceptions; investigate server-side details through protected operator tooling.
There is no end-user authentication, per-user isolation, rate limiting or HTTPS
in this assignment API. Treat notes as public demo data. A connection per request
keeps recovery simple for a small demonstration; a larger service would need
connection/concurrency capacity planning. Private-network deployment, non-root
execution, durable mounts, image delivery and backup/restore remain separate work.

Implementation references: [psycopg transactions and parameters](https://www.psycopg.org/psycopg3/docs/basic/usage.html),
[FastAPI lifespan testing](https://fastapi.tiangolo.com/advanced/testing-events/),
and the [PostgreSQL official image](https://hub.docker.com/_/postgres).
Application code is original; these references document the APIs used.
