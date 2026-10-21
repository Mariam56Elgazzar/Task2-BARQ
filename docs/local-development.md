# Local container development

Run commands from the repository root. This guide uses Windows PowerShell 5.1+
and Docker Desktop with Linux containers and the Compose plugin. Docker's modern
BuildKit builder is needed for the optional certificate mount. The stack needs
loopback port 8080 available. No local Python or PostgreSQL installation is needed.

## Build and start

```powershell
docker version
docker compose version
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/new-dev-env.ps1
docker build --file app/Dockerfile --tag notes-api:local .
docker compose --env-file .local/dev.env config --quiet
docker compose --env-file .local/dev.env up --detach --wait --wait-timeout 120
curl.exe --fail --show-error http://127.0.0.1:8080/readyz
```

Stop on a command failure. `-ExecutionPolicy Bypass` applies only to the launched
PowerShell process. The credential script preserves an existing file and otherwise
generates two independent random passwords. The development env file is plaintext,
ignored by Git, and excluded from the image context. It is not production secret
management. Keep it private and do not paste it, full container inspection output,
or resolved Compose configuration into logs or reviews. Use `config --quiet`.

The local image must be built explicitly: Compose uses `pull_policy: never` for
the API. After changing application code or dependencies, rebuild the image and
run `docker compose --env-file .local/dev.env up --detach --wait` again. A normal
unchanged `up` should retain existing containers and data.

Open <http://127.0.0.1:8080/docs> for the interactive API documentation.
The root URL `/` has no application endpoint; a 404 there is expected.

## Optional HTTPS inspection certificate

If the image builds until pip reports `CERTIFICATE_VERIFY_FAILED`, an HTTPS
inspection proxy or antivirus may be presenting a certificate the Linux image
does not trust. A successful Windows request alone does not establish container
trust. Identify the issuer and obtain its public CA certificate from your trusted
OS certificate store or administrator. Do not disable certificate verification.

For a verified Windows Trusted Root certificate, replace the placeholder below
with its actual thumbprint. Export the public certificate only:

```powershell
New-Item -ItemType Directory -Force .local/certs | Out-Null
$cert = Get-Item 'Cert:\CurrentUser\Root\REPLACE_WITH_VERIFIED_THUMBPRINT'
$bytes = $cert.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Cert)
$base64 = [Convert]::ToBase64String($bytes, [System.Base64FormattingOptions]::InsertLineBreaks)
$pem = "-----BEGIN CERTIFICATE-----`n$base64`n-----END CERTIFICATE-----`n"
$path = Join-Path (Get-Location).Path '.local/certs/build-ca.pem'
[System.IO.File]::WriteAllText($path, $pem, [System.Text.Encoding]::ASCII)
docker build --file app/Dockerfile --tag notes-api:local --secret "id=build_ca,src=.local/certs/build-ca.pem" .
```

The Dockerfile temporarily combines this CA with the standard roots and sets
`PIP_CERT` only inside the installation command. It deletes the temporary bundle
in the same layer; BuildKit removes the secret mount. The resulting application
image does not install this machine-specific CA into its runtime trust store.
The certificate file remains local and is covered by `*.pem` in `.gitignore`.
Build secret contents do not invalidate cached layers; use `--no-cache` if you
need to verify dependency installation against a changed CA.

## How the files fit together

| File | Responsibility |
| --- | --- |
| `app/Dockerfile` | Digest-pinned Python base, pinned runtime packages, UID/GID 10001, Uvicorn factory startup, authenticated readiness health check |
| `.dockerignore` | Allowlist of runtime sources; excludes credentials, repository metadata, tests, and unrelated files from the build context |
| `compose.yaml` | Three local services, startup ordering, restart policies, health checks, and persistent database volume |
| `docker/postgres/init.sql` | First-time restricted app-account creation, existing schema inclusion, and explicit grants |
| `docker/nginx/default.conf` | HTTP forwarding to `app:8000` and dynamic Docker DNS resolution |
| `scripts/new-dev-env.ps1` | Repeatable local credential generation without displaying or replacing passwords |
| `scripts/verify-local.ps1` | HTTP/database/identity/port checks, with optional database recreation |

Python, PostgreSQL and Nginx bases are pinned by manifest digest. The locally built
application is named `notes-api:local`; this is not a published registry release.
The Docker build context is the repository root, even though the Dockerfile is
under `app/`. Dependency installation is cached separately from application code.
Application files remain root-owned while the process runs as UID 10001.

Nginx publishes only `127.0.0.1:8080`. App port 8000 and DB port 5432 are not
published on the host. Compose DNS resolves `app` and `db` on its local network.
Nginx uses Docker's resolver plus an upstream shared-memory zone to refresh app
addresses. In AWS the database is on another host, so its private IP replaces
the local hostname `db`; this Compose file is not the AWS deployment template.

The `postgres` administrative account initializes `notes` and owns the table.
The API receives only the separate `notes_app` credentials, with table CRUD and
sequence USAGE grants and no database/role/schema creation privileges. The SQL
initializer reads the password from the environment and quotes it as an SQL
literal; the schema source remains `app/schema.sql`.

`pgdata` mounts at `/var/lib/postgresql/data`, appropriate for the selected
PostgreSQL 17 image. Initialization runs only for an empty data directory.
Changing env passwords or init SQL does not migrate an existing database.
Use explicit administrative changes for credential rotation or schema changes.

DB health checks server availability, not authentication. The API `/readyz`
queries the expected table with its own credentials. Nginx health checks that
same endpoint through the proxy. `/healthz` checks the HTTP process only.
`depends_on` orders initial startup; later recovery uses the application's fresh
DB connections and Nginx DNS refresh. An unhealthy status alone does not trigger
Docker's restart policy; that policy handles process exits.

## Verify real behavior

With the stack running:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/verify-local.ps1
```

This checks the running UID, port bindings, authenticated restricted database
access, rejection of a wrong password, absence of the temporary CA/admin password
in the API, HTTP creation/read/update/delete, and independent SQL visibility.
It creates a uniquely named test note and deletes only that note on success.
On failure, it may leave that test note for investigation; existing notes stay intact.

To additionally replace the database container and assert the same note survives:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/verify-local.ps1 -RecreateDatabase
```

This deliberately interrupts the local database, preserves the named volume,
checks the container ID changed, and waits for API recovery without replacing
the API container. Use this option for verification, not normal deployment.

Manual API example:

```powershell
$body = @{ title = 'My note'; content = 'Stored in PostgreSQL.' } | ConvertTo-Json
$note = Invoke-RestMethod http://127.0.0.1:8080/api/notes -Method Post -ContentType 'application/json' -Body $body
Invoke-RestMethod "http://127.0.0.1:8080/api/notes/$($note.id)"
```

## Stop, resume, and troubleshoot

```powershell
docker compose --env-file .local/dev.env ps
docker compose --env-file .local/dev.env logs --tail 50 app nginx
docker compose --env-file .local/dev.env stop
docker compose --env-file .local/dev.env up --detach --wait
```

`docker compose --env-file .local/dev.env down` removes containers and the project
network but retains the database volume. **Adding `--volumes` deletes the local
database data**; it is not a routine stop or troubleshooting step. There is no
automated backup/restore implementation in this local stack.

| Symptom | Check |
| --- | --- |
| Image missing | Run the explicit image build; no application registry pull is configured |
| Pip certificate error | Verify the issuer and use the optional build CA; do not change package pins to work around TLS |
| Required variable error | Generate credentials and include `--env-file .local/dev.env` |
| Port 8080 in use | Identify the other listener before changing or stopping anything |
| Nginx 502 | App health, container logs, service name and port, then DNS resolution |
| API readiness 503 | DB health, matching credentials, existing schema and grants |
| Read-only Nginx config startup message | Expected when the stock IPv6 helper attempts to edit our read-only mount; `nginx -t` must still pass |
| Init failure | Correct the reported SQL/mount problem; restarting with partially initialized data may skip init scripts. Preserve existing data and diagnose before any reset |

Local tests do not establish AWS network isolation, EBS mount ordering, host
reboot recovery, backup restoration, or production secret protection. The API
has no end-user authentication. Those deployment and recovery concerns remain
separate work.

## References

- [Docker build secrets](https://docs.docker.com/build/building/secrets/)
- [pip certificate configuration](https://pip.pypa.io/en/stable/topics/https-certificates/)
- [Official PostgreSQL image initialization](https://hub.docker.com/_/postgres)
- [Nginx upstream DNS resolution](https://nginx.org/en/docs/http/ngx_http_upstream_module.html#server)

The stack uses the official Python, PostgreSQL, and Nginx images. Project
configuration follows their documented interfaces; application source and schema
are maintained in this repository.
