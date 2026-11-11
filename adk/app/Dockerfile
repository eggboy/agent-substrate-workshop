# syntax=docker/dockerfile:1
# The workspace agent as an Agent Substrate actor image.
# PID 1 is shim/entrypoint.py, which runs `adk api_server` and survives SIGTERM (see that file).
FROM python:3.12-slim

# curl and git are what the agent's own shell tool reaches for in the workshop's egress drills.
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl git \
    && rm -rf /var/lib/apt/lists/*

COPY --from=ghcr.io/astral-sh/uv:0.13.4 /uv /uvx /bin/

WORKDIR /app
COPY pyproject.toml uv.lock ./
RUN uv sync --frozen --no-dev

COPY agents ./agents
COPY shim ./shim
RUN mkdir -p /workspace

ENV PATH=/app/.venv/bin:$PATH \
    PYTHONUNBUFFERED=1 \
    ADK_AGENTS_DIR=/app/agents \
    ADK_PORT=80 \
    AGENT_WORKSPACE_DIR=/workspace

EXPOSE 80
ENTRYPOINT ["python", "-m", "shim.entrypoint"]
