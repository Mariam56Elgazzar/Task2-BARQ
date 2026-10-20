"""A disposable, password-authenticated PostgreSQL server; never use an existing DB."""

import os
import secrets
import socket
import subprocess
import time
import uuid
from dataclasses import dataclass

import psycopg
import pytest
from fastapi.testclient import TestClient
from psycopg import sql

from app.config import Settings
from app.db import Database
from app.init_db import initialize
from app.main import create_app

POSTGRES_IMAGE = "postgres:17.11-bookworm"


def docker(*args, env=None, timeout=120):
    result = subprocess.run(
        ["docker", *args], env=env, capture_output=True, text=True, timeout=timeout,
        creationflags=subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0,
    )
    if result.returncode:
        # Container errors/logs can contain secrets; return only the operation name.
        raise RuntimeError(f"Docker {args[0]} failed; check Docker availability and image access")
    return result.stdout.strip()


def wait_for_database(database: Database):
    deadline = time.monotonic() + 60
    while time.monotonic() < deadline:
        try:
            with database.connect() as conn:
                conn.execute("SELECT 1")
            return
        except psycopg.Error:
            time.sleep(0.25)
    raise RuntimeError("Test PostgreSQL did not become ready within 60 seconds")


@dataclass
class Postgres:
    container: str
    owner: Database
    app: Database

    def stop(self):
        docker("stop", "--time", "5", self.container)

    def start(self):
        docker("start", self.container)
        wait_for_database(self.app)


@pytest.fixture(scope="session")
def postgres():
    # UUID name and randomly assigned loopback port avoid collisions with other work.
    name = "notes-api-test-" + uuid.uuid4().hex[:12]
    admin_password = secrets.token_urlsafe(32)
    app_password = secrets.token_urlsafe(32) + "'@:/?#"
    owner_password = secrets.token_urlsafe(32)
    # Docker reassigns an unspecified published port after stop/start. Select a
    # free port once and bind it explicitly so the application's address is stable.
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        port = listener.getsockname()[1]
    docker("info", "--format", "{{.ServerVersion}}")
    created = False
    try:
        docker(
            "run", "--detach", "--name", name,
            "--publish", f"127.0.0.1:{port}:5432",
            "--env", "POSTGRES_PASSWORD", "--env", "POSTGRES_DB=notes",
            "--env", "POSTGRES_HOST_AUTH_METHOD=scram-sha-256",
            POSTGRES_IMAGE,
            env={**os.environ, "POSTGRES_PASSWORD": admin_password}, timeout=300,
        )
        created = True
        port = int(docker("port", name, "5432/tcp").rsplit(":", 1)[1])
        admin = Database(Settings("127.0.0.1", "notes", "postgres", admin_password, port))
        wait_for_database(admin)
        with admin.connect() as conn:
            for role, password in (("notes_owner", owner_password), ("notes_app", app_password)):
                conn.execute(sql.SQL("CREATE ROLE {} LOGIN PASSWORD {} NOSUPERUSER NOCREATEDB NOCREATEROLE").format(
                    sql.Identifier(role), sql.Literal(password)
                ))
            conn.execute("REVOKE CREATE ON SCHEMA public FROM PUBLIC")
            conn.execute("GRANT USAGE, CREATE ON SCHEMA public TO notes_owner")
            conn.execute("GRANT USAGE ON SCHEMA public TO notes_app")
        owner = Database(Settings("127.0.0.1", "notes", "notes_owner", owner_password, port))
        application = Database(Settings("127.0.0.1", "notes", "notes_app", app_password, port))
        initialize(owner)
        with owner.connect() as conn:
            conn.execute("GRANT SELECT, INSERT, UPDATE, DELETE ON public.notes TO notes_app")
            conn.execute("GRANT USAGE ON SEQUENCE public.notes_id_seq TO notes_app")
        yield Postgres(name, owner, application)
    finally:
        if created:
            # Remove only this fixture's container and its anonymous data volume.
            docker("rm", "--force", "--volumes", name)


@pytest.fixture
def client(postgres):
    with postgres.owner.connect() as conn:
        conn.execute("TRUNCATE public.notes RESTART IDENTITY")
    with TestClient(create_app(postgres.app.settings)) as client:
        yield client
