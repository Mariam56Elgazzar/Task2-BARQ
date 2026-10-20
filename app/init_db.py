"""Explicit initial schema creation: python -m app.init_db."""

from pathlib import Path

import psycopg

from app.config import Settings
from app.db import Database


def initialize(database: Database):
    with database.connect() as conn:
        conn.execute(Path(__file__).with_name("schema.sql").read_text(encoding="utf-8"))


def main():
    try:
        initialize(Database(Settings.from_env()))
    except ValueError as exc:
        raise SystemExit(str(exc)) from None
    except psycopg.Error:
        raise SystemExit("Schema initialization failed; check DB availability and owner permissions.") from None
    print("Notes schema initialized.")


if __name__ == "__main__":
    main()
