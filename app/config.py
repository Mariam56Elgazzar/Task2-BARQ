"""Validate configuration without including credential values in errors."""

import os
from dataclasses import dataclass, field
from collections.abc import Mapping


@dataclass(frozen=True)
class Settings:
    host: str
    name: str
    user: str
    password: str = field(repr=False)
    port: int = 5432

    @classmethod
    def from_env(cls, env: Mapping[str, str] | None = None) -> "Settings":
        env = os.environ if env is None else env
        required = ("DB_HOST", "DB_NAME", "DB_USER", "DB_PASSWORD")
        missing = [key for key in required if not env.get(key, "").strip()]
        if missing:
            raise ValueError("Missing required configuration: " + ", ".join(missing))
        try:
            port = int(env.get("DB_PORT", "5432"))
            if not 1 <= port <= 65535:
                raise ValueError
        except ValueError:
            raise ValueError("DB_PORT must be an integer between 1 and 65535") from None
        # One host gives predictable connection retry behaviour; no DSN parsing.
        if any(char in env["DB_HOST"] for char in (",", "\x00", " ", "\n", "\r")):
            raise ValueError("DB_HOST must be one hostname or IP address")
        if any("\x00" in env[key] for key in required):
            raise ValueError("Database configuration cannot contain NUL characters")
        return cls(env["DB_HOST"], env["DB_NAME"], env["DB_USER"], env["DB_PASSWORD"], port)
