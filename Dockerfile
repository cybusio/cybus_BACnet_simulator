FROM ghcr.io/astral-sh/uv:0.6-python3.12-bookworm-slim AS builder
WORKDIR /app
COPY pyproject.toml uv.lock ./
RUN uv sync --frozen --no-dev --no-install-project
COPY src/ src/
RUN uv sync --frozen --no-dev

FROM python:3.12-slim-bookworm
WORKDIR /app
COPY --from=builder /app/.venv /app/.venv
COPY --from=builder /app/src /app/src
ENV PATH="/app/.venv/bin:$PATH"
RUN groupadd --gid 1001 app && useradd --uid 1001 --gid app --no-create-home app
RUN chown -R app:app /app
USER app
HEALTHCHECK --interval=30s --timeout=3s --retries=3 \
    CMD python -c "import os,urllib.request; urllib.request.urlopen(f'http://localhost:{os.environ.get(\"BACNET_METRICS_PORT\", \"9100\")}/metrics', timeout=3)"
ENTRYPOINT ["bacnet-sim"]
