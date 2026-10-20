-- Run explicitly during database provisioning, never from a health probe.
CREATE TABLE IF NOT EXISTS public.notes (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    title TEXT NOT NULL CHECK (char_length(title) BETWEEN 1 AND 200),
    content TEXT NOT NULL CHECK (char_length(content) BETWEEN 1 AND 10000),
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);
