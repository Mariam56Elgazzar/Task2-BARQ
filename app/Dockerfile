FROM python:3.11-slim-bookworm@sha256:f06d01d4ba3f8ad5af45a3ec87df19c1d317d8e8961edc0fabda61811af6f7cf

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

WORKDIR /app

COPY app/requirements.txt /tmp/requirements.txt

# Optionally trust an additional CA during dependency installation.
RUN --mount=type=secret,id=build_ca \
    set -eu; \
    if [ -f /run/secrets/build_ca ]; then \
        cat /etc/ssl/certs/ca-certificates.crt /run/secrets/build_ca > /tmp/pip-ca.pem; \
        export PIP_CERT=/tmp/pip-ca.pem; \
    fi; \
    python -m pip install --no-cache-dir -r /tmp/requirements.txt; \
    rm -f /tmp/pip-ca.pem

RUN groupadd --gid 10001 appuser \
    && useradd --uid 10001 --gid appuser \
       --no-create-home --no-log-init \
       --shell /usr/sbin/nologin appuser

COPY app/*.py app/schema.sql ./app/

USER 10001:10001

EXPOSE 8000

HEALTHCHECK --interval=10s --timeout=5s --start-period=40s --retries=3 \
    CMD ["python", "-c", "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8000/readyz', timeout=4).close()"]

CMD ["python", "-m", "uvicorn", "app.main:create_app", "--factory", "--host", "0.0.0.0", "--port", "8000"]
