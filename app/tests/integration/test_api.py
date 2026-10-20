import os
import socket
import subprocess
import sys
import time
from dataclasses import replace
from pathlib import Path

import httpx
import pytest
from fastapi.testclient import TestClient

from app.init_db import initialize
from app.main import create_app


def test_crud_is_committed_to_postgresql(client, postgres):
    payload = {"title": "Review demo", "content": "O'Reilly; DROP TABLE notes; -- مرحبا"}
    response = client.post("/api/notes", json=payload)
    assert response.status_code == 201
    note = response.json()
    note_id = note["id"]
    assert response.headers["Location"] == f"/api/notes/{note_id}"
    assert note["created_at"]
    with postgres.app.connect() as conn:
        row = conn.execute("SELECT title, content FROM public.notes WHERE id = %s", (note_id,)).fetchone()
    assert row == payload  # A separate authenticated connection sees the committed data.
    assert client.get(f"/api/notes/{note_id}").json() == note
    assert client.get("/api/notes").json() == [note]
    assert client.get("/api/notes?offset=1").json() == []
    changed = {"title": "Changed", "content": "Updated content"}
    update = client.put(f"/api/notes/{note_id}", json=changed)
    assert update.status_code == 200
    assert update.json()["created_at"] == note["created_at"]
    with postgres.app.connect() as conn:
        assert conn.execute("SELECT content FROM public.notes WHERE id = %s", (note_id,)).fetchone()["content"] == changed["content"]
    assert client.delete(f"/api/notes/{note_id}").status_code == 204
    with postgres.app.connect() as conn:
        assert conn.execute("SELECT id FROM public.notes WHERE id = %s", (note_id,)).fetchone() is None
    assert client.get(f"/api/notes/{note_id}").status_code == 404
    assert client.put(f"/api/notes/{note_id}", json=changed).status_code == 404
    assert client.delete(f"/api/notes/{note_id}").status_code == 404


@pytest.mark.parametrize("payload", [
    {}, {"title": " ", "content": "body"}, {"title": "a" * 201, "content": "body"},
    {"title": "ok", "content": ""}, {"title": "ok", "content": "a" * 10001},
    {"title": 123, "content": "body"}, {"title": "ok", "content": "null\x00byte"},
    {"title": "ok", "content": "body", "password": "do-not-echo-this"},
])
def test_invalid_body_does_not_write_or_echo_input(client, postgres, payload):
    response = client.post("/api/notes", json=payload)
    assert response.status_code == 422
    assert "do-not-echo-this" not in response.text
    with postgres.app.connect() as conn:
        assert conn.execute("SELECT count(*) AS total FROM public.notes").fetchone()["total"] == 0


@pytest.mark.parametrize("path", [
    "/api/notes/0", "/api/notes/-1", "/api/notes/not-an-id", "/api/notes/9223372036854775808",
    "/api/notes?limit=0", "/api/notes?limit=101", "/api/notes?offset=-1",
])
def test_bad_id_and_pagination(client, path):
    assert client.get(path).status_code == 422


def test_list_pagination_and_invalid_update(client):
    notes = [client.post("/api/notes", json={"title": str(i), "content": "body"}).json() for i in range(3)]
    assert client.get("/api/notes?limit=2&offset=1").json() == notes[1:]
    response = client.put(f"/api/notes/{notes[0]['id']}", json={"title": "replacement"})
    assert response.status_code == 422
    assert client.get(f"/api/notes/{notes[0]['id']}").json() == notes[0]


def test_application_role_is_restricted(client, postgres):
    with postgres.app.connect() as conn:
        row = conn.execute(
            "SELECT rolsuper, rolcreatedb, rolcreaterole FROM pg_roles WHERE rolname = current_user"
        ).fetchone()
        assert row == {"rolsuper": False, "rolcreatedb": False, "rolcreaterole": False}
        assert conn.execute("SELECT has_schema_privilege(current_user, 'public', 'CREATE') AS allowed").fetchone()["allowed"] is False
    assert client.get("/readyz").status_code == 200


def test_missing_select_grant_is_not_ready(client, postgres):
    with postgres.owner.connect() as conn:
        conn.execute("REVOKE SELECT ON public.notes FROM notes_app")
    try:
        assert client.get("/healthz").status_code == 200
        assert client.get("/readyz").status_code == 503
    finally:
        with postgres.owner.connect() as conn:
            conn.execute("GRANT SELECT ON public.notes TO notes_app")
    assert client.get("/readyz").status_code == 200


def test_locked_table_fails_safely_and_recovers(client, postgres):
    with postgres.owner.connect() as conn:
        conn.execute("LOCK TABLE public.notes IN ACCESS EXCLUSIVE MODE")
        response = client.post("/api/notes", json={"title": "blocked", "content": "must not commit"})
        assert response.status_code == 503
        assert response.json() == {"detail": "Database unavailable"}
    assert client.get("/api/notes").json() == []
    assert client.post("/api/notes", json={"title": "unblocked", "content": "can commit"}).status_code == 201


def test_missing_schema_is_not_ready_and_probe_does_not_recreate_it(client, postgres):
    with postgres.owner.connect() as conn:
        conn.execute("ALTER TABLE public.notes RENAME TO notes_unavailable")
    try:
        assert client.get("/healthz").status_code == 200
        assert client.get("/readyz").status_code == 503
        assert client.get("/api/notes").status_code == 503
    finally:
        with postgres.owner.connect() as conn:
            conn.execute("ALTER TABLE public.notes_unavailable RENAME TO notes")
    assert client.get("/readyz").status_code == 200


def test_wrong_password_is_not_ready_and_is_not_leaked(postgres, caplog):
    bad = replace(postgres.app.settings, password="invalid-password-do-not-log")
    with TestClient(create_app(bad)) as client:
        assert client.get("/healthz").status_code == 200
        response = client.get("/readyz")
        assert response.status_code == 503
        assert response.json() == {"detail": "Database unavailable"}
        assert client.post("/api/notes", json={"title": "x", "content": "y"}).status_code == 503
        assert bad.password not in response.text + caplog.text
        assert postgres.app.settings.password not in caplog.text


def test_existing_app_recovers_after_actual_database_stop_start(client, postgres):
    note = client.post("/api/notes", json={"title": "Survives restart", "content": "stored in PostgreSQL"}).json()
    postgres.stop()
    try:
        assert client.get("/healthz").status_code == 200
        assert client.get("/readyz").status_code == 503
        assert client.post("/api/notes", json={"title": "during outage", "content": "fails safely"}).status_code == 503
    finally:
        postgres.start()
    assert client.get("/readyz").status_code == 200
    assert client.get(f"/api/notes/{note['id']}").json() == note
    assert client.post("/api/notes", json={"title": "after recovery", "content": "works"}).status_code == 201


def test_app_can_start_during_outage_and_recover_without_restart(postgres):
    postgres.stop()
    try:
        with TestClient(create_app(postgres.app.settings)) as client:
            assert client.get("/healthz").status_code == 200
            assert client.get("/readyz").status_code == 503
            postgres.start()
            assert client.get("/readyz").status_code == 200
    finally:
        postgres.start()


def test_schema_initialization_preserves_existing_data(client, postgres):
    note = client.post("/api/notes", json={"title": "Keep", "content": "do not reset"}).json()
    initialize(postgres.owner)
    initialize(postgres.owner)
    assert client.get(f"/api/notes/{note['id']}").json() == note


def test_real_http_server_persists_a_request(postgres):
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        port = listener.getsockname()[1]
    config = postgres.app.settings
    env = {**os.environ, "DB_HOST": config.host, "DB_PORT": str(config.port),
           "DB_NAME": config.name, "DB_USER": config.user, "DB_PASSWORD": config.password}
    process = subprocess.Popen(
        [sys.executable, "-m", "uvicorn", "app.main:create_app", "--factory", "--host", "127.0.0.1", "--port", str(port)],
        cwd=Path(__file__).resolve().parents[3], env=env,
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        creationflags=subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0,
    )
    try:
        with httpx.Client(base_url=f"http://127.0.0.1:{port}", timeout=5) as client:
            deadline = time.monotonic() + 30
            while time.monotonic() < deadline:
                assert process.poll() is None, "Uvicorn exited before becoming ready"
                try:
                    if client.get("/readyz").status_code == 200:
                        break
                except httpx.TransportError:
                    pass
                time.sleep(0.1)
            else:
                pytest.fail("HTTP server did not become ready")
            response = client.post("/api/notes", json={"title": "HTTP proof", "content": "Verified using a separate SQL connection"})
            assert response.status_code == 201
            note_id = response.json()["id"]
            assert client.get(f"/api/notes/{note_id}").status_code == 200
            with postgres.app.connect() as conn:
                assert conn.execute("SELECT title FROM public.notes WHERE id = %s", (note_id,)).fetchone()["title"] == "HTTP proof"
            print(f"HTTP POST returned 201; note {note_id} independently verified in PostgreSQL.")
    finally:
        process.terminate()
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=10)
