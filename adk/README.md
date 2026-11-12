# Agent Substrate on GKE with Google ADK

A half-day, hands-on track on top of the [Agent Substrate workshop](../README.md). The morning
modules teach the primitives with a 1 MB Go process; this track runs a real agent, Google ADK's
`adk api_server` with a workspace agent, as an actor, and measures what Substrate does for it:
golden snapshots, suspend and resume, credentials that never enter the sandbox, survival of worker
loss, density, and a like-for-like run of the same image on Agent Sandbox on GKE.

Every number in the labs was measured on the reference environment (GKE 1.37 Rapid, two c3-standard-4
workers, Substrate v1.0.0, ADK 2.14, `gemini-3.8-flash`). Attendees measure their own and compare.

## Agenda (4 hours)

| Time | Block | Min | Where |
|---|---|---|---|
| 0:00 | Orientation, environment check | 10 | official module 0 |
| 0:10 | Architecture: actors, workers, snapshots, router, egress | 15 | official module 1 |
| 0:25 | Primitives with the Go agent: template, golden snapshot, MEMORY vs VOLUMES | 25 | official modules 2 and 3 |
| 0:50 | **Lab 1** An ADK agent as an actor | 30 | [labs/01-adk-actor](labs/01-adk-actor/README.md) |
| 1:20 | **Lab 2** Egress and credentials: injected key, then no key at all | 20 | [labs/02-credentials](labs/02-credentials/README.md) |
| 1:40 | Break | 15 | |
| 1:55 | **Lab 3** Long-running sessions under interruption | 30 | [labs/03-interruptions](labs/03-interruptions/README.md) |
| 2:25 | **Lab 4** Density, parking and idle | 35 | [labs/04-density](labs/04-density/README.md) |
| 3:00 | **Lab 5** Like-for-like with Agent Sandbox on GKE | 40 | [labs/05-agent-sandbox](labs/05-agent-sandbox/README.md) |
| 3:40 | **Lab 6** Observe and operate | 15 | [labs/06-observe](labs/06-observe/README.md) |
| 3:55 | Wrap-up and cleanup | 5 | official module 7 |

Cut lines when behind, in order: Lab 2 approach B becomes a demo; Lab 3 Part B (crash and revert) becomes a
demo; Lab 4 step 4 (four clients, more workers) is skipped; Lab 5 step 4 is skipped.

## What is in this directory

| Path | Purpose |
|---|---|
| [`app/`](app/) | The ADK agent (`agents/workspace`), the PID 1 shim (`shim/entrypoint.py`), tests, Dockerfile. `uv run pytest` runs offline. |
| [`manifests/`](manifests/) | ActorTemplates `adk-v1`, `adk-vertex-v1`, `adk-exit-v1`; the ADK worker pool; egress policies for approach A (injected key) and B (actor JWT); the Agent Sandbox manifests. |
| [`scripts/`](scripts/) | `turn.sh` (one timed ADK turn), the drills (`drill-confirm.sh`, `drill-evict.sh`, `drill-midturn.sh`, `drill-sandbox.sh`), `load.sh` (density), `build-image.sh`, `catch-up.sh`, `verify/`. |
| [`labs/`](labs/) | The six labs. |

The gateway (`app/cmd/gateway` in the repository root) carries three ADK additions: a streaming reverse proxy
at `/adk/{actor}/...`, a synchronous self-suspend at `POST /actors/{actor}/suspend` for the shim's SIGTERM
path, and the `/genai` Vertex proxy for approach B.

## Make targets

```bash
make adk-image                 # Cloud Build adk/app -> .workshop/adk-image (digest-pinned)
make adk-catch-up LAB=N        # bring the environment to the start of lab N (RESET=1 recreates templates)
make adk-verify LAB=N          # check the end state of lab N
make forward-gateway           # http://localhost:8081, used by every ADK command
make idle-on IDLE_AFTER=5s     # the gateway's idle-suspend policy; make idle-off for Lab 3
```

## Before the event

In addition to the official pre-event steps (`make gcp`, `make install`, `make build`, `make gateway`):

1. A Gemini Developer API key restricted to `generativelanguage.googleapis.com`, stored as Secret
   `workshop-secrets/gemini` (key `key`), and the credential provider's namespace policy allowing the atespace.
   `make adk-catch-up LAB=1` checks both and prints the commands if they are missing.
2. `make adk-image` (about 2 minutes on Cloud Build).
3. For Lab 5: `make adk-sandbox-setup` (gVisor node pool, snapshot bucket and IAM, Agent Sandbox controller, the
   lab manifests); the cluster needs `--enable-pod-snapshots`. Details in
   [labs/05-agent-sandbox](labs/05-agent-sandbox/README.md#setup-done-before-the-event-make-adk-sandbox-setup-runs-it).
4. `make adk-catch-up LAB=2` (the end state of Lab 1), then `make adk-verify LAB=1` once by hand, so the first
   attendee is not the test. Then remove what Lab 1 creates, so attendees create it themselves:
   `kubectl ate delete actor ws -a workshop; kubectl ate delete actor-template adk-v1 -a workshop`.

## What the labs do not claim

- Substrate is not faster than Agent Sandbox at snapshotting a gVisor sandbox; both do it in seconds. The
  difference is who triggers the wake, what happens on eviction, and where credentials and network policy live.
- Idle density (sessions that exist) and active concurrency (sessions on a worker at the same instant) are
  different numbers with different knobs. Lab 4 measures both and does not quote a ratio.
- The gateway's suspend endpoint and `/genai` proxy are workshop code: no authentication, JWT decoded but not
  verified. The labs say where a production gateway would differ.
