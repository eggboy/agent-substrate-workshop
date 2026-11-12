# Lab 1: An ADK agent as an actor (30 min)

The morning's Go agent taught the primitives with a 1 MB process. This lab runs a real agent:
Google ADK's `adk api_server` hosting a workspace agent (shell, file and edit tools over
`/workspace`, a confirmation-gated publish tool, in-memory sessions). Nothing in the agent knows
about Substrate. You measure what it costs to make that process durable and suspendable from the
outside, and what survives a suspend.

## Read before you type

- [`adk/app/agents/workspace/agent.py`](../../app/agents/workspace/agent.py): the agent. `EnvironmentToolset(LocalEnvironment)` gives it
  read, write, edit and execute over `/workspace`; `FunctionTool(publish_report, require_confirmation=True)` is the
  risky action that waits for a human (Lab 3); `App(resumability_config=ResumabilityConfig(is_resumable=True))`
  lets a cut turn be resumed (Lab 3). Sessions live in process memory: `--session_service_uri=memory://`.
- [`adk/app/shim/entrypoint.py`](../../app/shim/entrypoint.py): PID 1 in the image. It runs `adk api_server` as a child and owns
  the SIGTERM policy. Lab 3 is about why that exists; for now, it is a 180-line supervisor.
- [`adk/manifests/template-adk-v1.yaml.tmpl`](../../manifests/template-adk-v1.yaml.tmpl): the ActorTemplate. Compare it with the Go
  agent's `agent-v3`:

  | | `agent-v3` (Go, module 4) | `adk-v1` |
  |---|---|---|
  | `wakeupProbe` | `GET /readyz` | `GET /health` (an `adk api_server` route) |
  | Model access | gateway `/v1/model` with Workload Identity | the agent calls Gemini itself; the key is injected by the egress gateway (Lab 2) |
  | `GOOGLE_API_KEY` | none | a literal placeholder; template env is baked into every snapshot, so never a real key |
  | `SSL_CERT_FILE` | none | the projected trust bundle, so httpx trusts the egress MITM |
  | `actorMetadata` volume | none | `/run/ate/actor-name`: how the shim learns who it is |
  | `memoryBytes` | 512 MiB | 1.5 GiB (Python, google-genai, the ADK server) |
  | Worker pool | `agents` (1 CPU, 1 GiB) | `adk-agents` (2 CPU, 2 GiB), label `workload: adk-agent` |

## Steps

1. The image is built (`make adk-image`, done before the event) and the pool exists. Create the template and watch
   the golden snapshot build:
   ```bash
   source scripts/env.sh
   cat .workshop/adk-image
   kubectl ate get workers -n workshop                      # two adk-agents workers, 0 actors each
   date +%T; scripts/render.sh adk/manifests/template-adk-v1.yaml.tmpl | kubectl ate create actor-template -f -
   until kubectl ate get actor-template adk-v1 -a workshop -o json 2>/dev/null | jq -e '.status.goldenSnapshotStatus | (.goldenTag.name // .errorMessage)' >/dev/null; do sleep 2; done; date +%T
   kubectl ate get actor-template adk-v1 -a workshop -o json | jq .status.goldenSnapshotStatus
   ```
   Substrate started the container on a worker, waited for `/health`, checkpointed the whole process and uploaded
   it. Measured while building the lab: **28 s**, 34 MB compressed (27 MB memory pages, 7 MB rootfs changes).
   Every actor of this template starts from that image of a warm Python process, not from `python -m`.
2. Create your actor. It is born SUSPENDED: nothing runs until someone talks to it.
   ```bash
   kubectl ate create actor ws --template=adk-v1 -a workshop
   make egress POLICY=adk/manifests/egress-adk.yaml ACTOR=ws
   kubectl ate get actor ws -a workshop
   ```
   The egress policy is the subject of Lab 2. Without it the agent cannot reach the model.
3. Talk to it through the gateway. The gateway's `/adk/{actor}/...` route is a streaming reverse proxy: it sets the
   `ate-target-actor` header and lets atenet-router park the request while the actor resumes.
   ```bash
   make forward-gateway                                    # http://localhost:8081
   time curl -s localhost:8081/adk/ws/health               # the first request: placement + restore from the golden snapshot
   curl -s localhost:8081/adk/ws/list-apps
   kubectl ate get actor ws -a workshop                     # RUNNING, on a worker
   ```
   Measured: **1.1 s** for the first request when a worker is free; 7 s the very first time a node restores
   this template (it pulls the snapshot from the bucket once).
4. Open a session and run two turns with ADK's own REST contract (`adk/scripts/turn.sh` wraps exactly this):
   ```bash
   curl -s -X POST -H 'Content-Type: application/json' -d '{}' localhost:8081/adk/ws/apps/workspace/users/u1/sessions/s1
   adk/scripts/turn.sh ws "Reply with exactly one word: ready"
   adk/scripts/turn.sh ws "Create /workspace/notes.md containing the line: lab 1 ok. Then run wc -c on it and tell me the result."
   ```
   `turn.sh` prints the model's text and a timing line: `session_call` is the first request of the turn (the one that
   carries a resume if the actor was suspended), `total` the whole turn. Expect 2 to 4 s for a text answer and
   10 to 15 s for a turn with tool calls.
5. Suspend it, synchronously, and look at what is left:
   ```bash
   time kubectl ate suspend actor ws -a workshop --mode=sync
   kubectl ate get workers -n workshop                      # both adk-agents workers free again
   gcloud storage du -sh gs://${BUCKET_NAME}/atespaces/workshop/actors/
   ```
   `--mode=sync` returns when the snapshot is in the bucket: **2.9 s** measured, 37 MB after a few turns. An
   asynchronous suspend returns in about 1.5 s and uploads later; Lab 3 explains when that difference matters.
6. Ask the agent what it remembers:
   ```bash
   adk/scripts/turn.sh ws "What word did I ask you to reply with first, and what does /workspace/notes.md contain? One line."
   kubectl ate get actor ws -a workshop
   ```
   The session (process memory) and the file (`durableDir`) both came back; the `session_call` time is the resume,
   0.2 to 1.2 s. The WORKER POD may be the other worker: the snapshot, not the worker, is the actor.

## What just happened

- `adk api_server` needed no change to become an actor: a health route for `wakeupProbe`, a writable directory, and
  the shim as PID 1. The template is where Substrate-specific decisions live.
- The golden snapshot replaces startup. The 28 s is paid once per template, not once per session.
- A suspended ADK session is a 37 MB object. Twenty of them hold no worker (Lab 4).
- Two things the agent must not keep in process memory across a suspend: a real credential (Lab 2) and a belief
  about time passing or connections being alive (Lab 3).

## Checkpoint

```bash
make adk-verify LAB=1
```

**Stuck?** Run `make adk-catch-up LAB=2` (add `RESET=1` if `adk-v1` or `ws` is broken).

Next: [Egress and credentials](../02-credentials/README.md)
