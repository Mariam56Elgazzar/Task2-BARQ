"""Short transactions and fresh connections let requests recover after DB outages."""

import logging
import time

import psycopg
from psycopg.rows import dict_row

from app.config import Settings

logger = logging.getLogger(__name__)


class Database:
    def __init__(self, settings: Settings):
        self.settings = settings

    def connect(self):
        return psycopg.connect(
            host=self.settings.host,
            port=self.settings.port,
            dbname=self.settings.name,
            user=self.settings.user,
            password=self.settings.password,
            connect_timeout=3,
            options="-c statement_timeout=3000 -c lock_timeout=2000",
            application_name="notes-api",
            row_factory=dict_row,
        )

    def ready(self):
        with self.connect() as conn:
            # Authenticated query also verifies the expected schema and SELECT grant.
            conn.execute("SELECT id, title, content, created_at FROM public.notes LIMIT 0")

    def wait_until_ready(self, attempts: int = 4) -> bool:
        for attempt in range(attempts):
            try:
                self.ready()
                return True
            except psycopg.Error:
                # Do not log exception text: libpq errors can contain connection data.
                logger.warning("Database readiness attempt %d/%d failed", attempt + 1, attempts)
                if attempt + 1 < attempts:
                    time.sleep(min(0.5 * 2**attempt, 2))
        return False
