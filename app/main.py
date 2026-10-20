"""HTTP contract for the notes API. Run with uvicorn app.main:create_app --factory."""

import logging
from contextlib import asynccontextmanager
from datetime import datetime
from typing import Annotated

import psycopg
from fastapi import FastAPI, HTTPException, Path, Query, Request, Response
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from pydantic import BaseModel, ConfigDict, Field, field_validator
from starlette.concurrency import run_in_threadpool

from app.config import Settings
from app.db import Database

logger = logging.getLogger(__name__)
NoteId = Annotated[int, Path(ge=1, le=9223372036854775807)]


class NoteInput(BaseModel):
    model_config = ConfigDict(extra="forbid", strict=True)
    title: str = Field(min_length=1, max_length=200)
    content: str = Field(min_length=1, max_length=10000)

    @field_validator("title", "content")
    @classmethod
    def valid_text(cls, value: str) -> str:
        if not value.strip() or "\x00" in value:
            raise ValueError("Must contain text and cannot contain NUL characters")
        return value


class Note(NoteInput):
    id: int
    created_at: datetime


def create_app(settings: Settings | None = None) -> FastAPI:
    database = Database(settings or Settings.from_env())

    @asynccontextmanager
    async def lifespan(app: FastAPI):
        if not await run_in_threadpool(database.wait_until_ready):
            logger.warning("Starting with database unavailable; readiness remains 503 until recovery")
        yield

    app = FastAPI(title="Notes API", version="0.1.0", lifespan=lifespan)

    @app.exception_handler(psycopg.Error)
    async def database_error(request: Request, exc: psycopg.Error):
        logger.warning("Database operation failed (%s)", type(exc).__name__)
        return JSONResponse(status_code=503, content={"detail": "Database unavailable"})

    @app.exception_handler(RequestValidationError)
    async def invalid_request(request: Request, exc: RequestValidationError):
        # FastAPI's default error includes rejected input. Never echo request data.
        return JSONResponse(status_code=422, content={"detail": "Invalid request; see /docs for field constraints"})

    @app.get("/healthz")
    def health():
        return {"status": "ok"}

    @app.get("/readyz")
    def ready():
        database.ready()
        return {"status": "ready"}

    @app.post("/api/notes", response_model=Note, status_code=201)
    def create_note(note: NoteInput, response: Response):
        with database.connect() as conn:
            row = conn.execute(
                "INSERT INTO public.notes (title, content) VALUES (%s, %s) "
                "RETURNING id, title, content, created_at",
                (note.title, note.content),
            ).fetchone()
        response.headers["Location"] = f"/api/notes/{row['id']}"
        return row

    @app.get("/api/notes", response_model=list[Note])
    def list_notes(
        limit: Annotated[int, Query(ge=1, le=100)] = 50,
        offset: Annotated[int, Query(ge=0, le=2147483647)] = 0,
    ):
        with database.connect() as conn:
            return conn.execute(
                "SELECT id, title, content, created_at FROM public.notes ORDER BY id LIMIT %s OFFSET %s",
                (limit, offset),
            ).fetchall()

    @app.get("/api/notes/{note_id}", response_model=Note)
    def read_note(note_id: NoteId):
        with database.connect() as conn:
            row = conn.execute(
                "SELECT id, title, content, created_at FROM public.notes WHERE id = %s", (note_id,)
            ).fetchone()
        if row is None:
            raise HTTPException(404, "Note not found")
        return row

    @app.put("/api/notes/{note_id}", response_model=Note)
    def update_note(note_id: NoteId, note: NoteInput):
        with database.connect() as conn:
            row = conn.execute(
                "UPDATE public.notes SET title = %s, content = %s WHERE id = %s "
                "RETURNING id, title, content, created_at",
                (note.title, note.content, note_id),
            ).fetchone()
        if row is None:
            raise HTTPException(404, "Note not found")
        return row

    @app.delete("/api/notes/{note_id}", status_code=204)
    def delete_note(note_id: NoteId):
        with database.connect() as conn:
            row = conn.execute("DELETE FROM public.notes WHERE id = %s RETURNING id", (note_id,)).fetchone()
        if row is None:
            raise HTTPException(404, "Note not found")
        return Response(status_code=204)

    return app
