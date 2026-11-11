# Workspace agent (ADK) as a Substrate actor

A Google ADK agent that reads, writes and runs code in `/workspace`, keeps its session in process
memory, and asks a human before publishing. The image runs `adk api_server` behind a PID 1 shim that
survives SIGTERM so the actor can be suspended instead of crashing when its worker goes away.

| Path | What |
|---|---|
| `agents/workspace/` | The ADK app (`agent.py`, `tools.py`). `adk api_server /app/agents` serves it as app `workspace`. |
| `shim/entrypoint.py` | PID 1: starts the ADK server, handles SIGTERM, asks the gateway to suspend the actor. |
| `tests/` | Offline unit tests. |

## Local run

```bash
uv sync
export GOOGLE_API_KEY=...            # or GOOGLE_GENAI_USE_VERTEXAI=TRUE with ADC
export AGENT_WORKSPACE_DIR=$PWD/.workspace && mkdir -p "$AGENT_WORKSPACE_DIR"
SHIM_EXIT_ON_SIGTERM=1 ADK_PORT=8000 ADK_AGENTS_DIR=agents uv run python -m shim.entrypoint
```

Then, in another shell:

```bash
curl -s -X POST localhost:8000/apps/workspace/users/u1/sessions/s1 -H 'Content-Type: application/json' -d '{}'
curl -s -X POST localhost:8000/run -H 'Content-Type: application/json' \
  -d '{"appName":"workspace","userId":"u1","sessionId":"s1","newMessage":{"role":"user","parts":[{"text":"Create hello.py that prints the date, run it."}]}}' | jq '.[-1].content.parts[0].text'
```

## Checks

```bash
uv run ruff check --fix . && uv run ruff format .
uv run pytest
```

## Build

Built by Cloud Build from this directory (no local Docker needed):

```bash
gcloud builds submit --tag REGION-docker.pkg.dev/PROJECT/workshop/adk-workspace:dev adk/app
```

The ActorTemplate must reference the image by digest.
