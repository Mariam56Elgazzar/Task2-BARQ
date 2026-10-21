"""Exercise a built image against a disposable PostgreSQL container.

Uses unique container/network names and no published ports. Never touches the
development Compose project or its data. Requires only Python's standard library.
"""

import os
from pathlib import Path
import secrets
import subprocess
import sys
import time
import uuid

POSTGRES_IMAGE = "postgres:17.11-bookworm@sha256:858bb5e98eed02eb8cafbcdc007f9a65d1b613972028944a8ec2133ccaf80d27"


def docker(*args, env=None, stdin=None, check=True):
    result = subprocess.run(
        ["docker", *args], input=stdin, env=env, text=True,
        capture_output=True, timeout=300,
    )
    if check and result.returncode:
        # Docker output may include configuration; never print credentials/logs.
        raise RuntimeError(f"Docker {args[0]} failed (exit {result.returncode})")
    return result


def wait_healthy(container):
    deadline = time.monotonic() + 100
    while time.monotonic() < deadline:
        status = docker("inspect", "--format", "{{.State.Health.Status}}", container).stdout.strip()
        if status == "healthy":
            return
        if status == "unhealthy":
            raise RuntimeError("Image did not become healthy; inspect health locally without sharing secrets")
        time.sleep(2)
    raise RuntimeError("Timed out waiting for image readiness")


def main(image):
    root = Path(__file__).resolve().parents[1]
    name = "notes-image-check-" + uuid.uuid4().hex[:12]
    database, application = name + "-db", name + "-app"
    credentials = {**os.environ, "POSTGRES_PASSWORD": secrets.token_urlsafe(32),
                   "DB_APP_PASSWORD": secrets.token_urlsafe(32)}
    created_network = False
    try:
        docker("network", "create", name)
        created_network = True
        docker(
            "run", "--detach", "--name", database, "--network", name, "--network-alias", "db",
            "--env", "POSTGRES_DB=notes", "--env", "POSTGRES_PASSWORD", "--env", "DB_APP_PASSWORD",
            "--tmpfs", "/var/lib/postgresql/data",
            "--mount", f"type=bind,src={root / 'docker/postgres/init.sql'},dst=/docker-entrypoint-initdb.d/10-init.sql,readonly",
            "--mount", f"type=bind,src={root / 'app/schema.sql'},dst=/opt/notes/schema.sql,readonly",
            "--health-cmd", "pg_isready -h 127.0.0.1 -U postgres -d notes",
            "--health-interval", "2s", "--health-timeout", "3s", "--health-retries", "30",
            POSTGRES_IMAGE, env=credentials,
        )
        wait_healthy(database)
        docker(
            "run", "--detach", "--name", application, "--network", name,
            "--env", "DB_HOST=db", "--env", "DB_PORT=5432", "--env", "DB_NAME=notes",
            "--env", "DB_USER=notes_app", "--env", "DB_PASSWORD", image,
            env={**os.environ, "DB_PASSWORD": credentials["DB_APP_PASSWORD"]},
        )
        wait_healthy(application)
        # This code runs inside the exact image that will be scanned/published.
        probe = '''
import json
import os
import urllib.error
import urllib.request
from app.config import Settings
from app.db import Database

assert os.getuid() == 10001
assert 'POSTGRES_PASSWORD' not in os.environ
assert 'PIP_CERT' not in os.environ
assert not os.path.exists('/run/secrets/build_ca')
assert not os.path.exists('/tmp/pip-ca.pem')

def request(path, method='GET', data=None):
    body = None if data is None else json.dumps(data).encode()
    req = urllib.request.Request('http://127.0.0.1:8000' + path, data=body,
                                 method=method, headers={'Content-Type': 'application/json'})
    with urllib.request.urlopen(req, timeout=10) as response:
        raw = response.read()
        return response.status, json.loads(raw) if raw else None

assert request('/readyz') == (200, {'status': 'ready'})
payload = {'title': 'Release image check', 'content': "O'Reilly; stored safely"}
status, note = request('/api/notes', 'POST', payload)
assert status == 201
with Database(Settings.from_env()).connect() as conn:
    role = conn.execute('SELECT current_user AS name, rolsuper, rolcreatedb, rolcreaterole FROM pg_roles WHERE rolname = current_user').fetchone()
    assert role['name'] == 'notes_app'
    assert not any(role[key] for key in ('rolsuper', 'rolcreatedb', 'rolcreaterole'))
    row = conn.execute('SELECT title, content FROM public.notes WHERE id = %s', (note['id'],)).fetchone()
    assert row == payload
assert request('/api/notes/' + str(note['id'])) == (200, note)
status, updated = request('/api/notes/' + str(note['id']), 'PUT', {**payload, 'content': 'Updated'})
assert status == 200 and updated['content'] == 'Updated'
assert request('/api/notes/' + str(note['id']), 'DELETE')[0] == 204
try:
    request('/api/notes/' + str(note['id']))
except urllib.error.HTTPError as exc:
    assert exc.code == 404
else:
    raise AssertionError('Deleted note still exists')
print('PASS: packaged image UID, readiness, restricted DB login, committed CRUD, and build-secret absence')
'''
        result = docker("exec", "--interactive", application, "python", "-", stdin=probe)
        print(result.stdout.strip())
    finally:
        # Names are unique to this invocation; no development resources are removed.
        for container in (application, database):
            docker("rm", "--force", "--volumes", container, check=False)
        if created_network:
            docker("network", "rm", name, check=False)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("Usage: python scripts/verify-image.py IMAGE")
    main(sys.argv[1])
