# Lab 3: Long-running sessions under interruption (30 min)

An agent session lives for hours or days. In that time the human walks away, a node is drained,
a Spot VM is reclaimed, a tool call is halfway through when the pod disappears. This lab puts
the ADK actor from Lab 1 through each of those and measures what survives. Two of the four
parts come from failures found while building this workshop; they are in here because every
team that runs agents on Substrate will meet them.

You need the actor `ws` from Lab 1 (template `adk-v1`), the gateway port-forward, and the gateway's
idle-suspend **off**: this lab decides itself when an actor is suspended, and a 5 s idle policy would
suspend `fragile` and `ws` between your commands. With the policy off, nothing frees a worker for you
either, and there are two: start with every ADK actor suspended (`make adk-catch-up LAB=3` does all of this).

```bash
source scripts/env.sh
make idle-off                              # IDLE_AFTER=0s; Lab 4 turns it back on
kubectl ate suspend actor wsv -a workshop 2>/dev/null; kubectl ate suspend actor ws -a workshop 2>/dev/null
make forward-gateway                       # http://localhost:8081
kubectl ate get workers -n workshop        # 0 actors on both adk-agents workers
```

## Part A: Approval tomorrow

`publish_report` in [`agents/workspace/agent.py`](../../app/agents/workspace/agent.py) is wrapped in
`FunctionTool(..., require_confirmation=True)`, and the app is resumable. When the agent wants to
publish, ADK stops the turn and emits an `adk_request_confirmation` function call instead of
running the tool. The human may answer in a minute or next week. What does the session cost
in between?

1. Ask for a publication. Keep the request id from the stream:
   ```bash
   S=approval-$RANDOM
   curl -s -X POST -H 'Content-Type: application/json' -d '{}' \
     localhost:8081/adk/ws/apps/workspace/users/u1/sessions/$S >/dev/null
   curl -s -N -X POST -H 'Content-Type: application/json' localhost:8081/adk/ws/run_sse -d '{
     "appName":"workspace","userId":"u1","sessionId":"'$S'",
     "newMessage":{"role":"user","parts":[{"text":"Create /workspace/report.md with one line: lab 3 report. Then publish it with publish_report. Do not ask me anything."}]}}' \
     | sed -n 's/^data: //p' | tee /tmp/step1.json | jq -c '{author, fc: [.content.parts[]?.functionCall.name // empty], text: [.content.parts[]?.text // empty]}'
   REQ=$(jq -r '.content.parts[]? | select(.functionCall.name=="adk_request_confirmation") | .functionCall.id' /tmp/step1.json | head -1); echo "request id: $REQ"
   ```
   The last event carries `adk_request_confirmation` and no `publish_report` response: the tool did not run.
2. The human is away. Suspend the actor and look at the workers:
   ```bash
   kubectl ate suspend actor ws -a workshop --mode=sync
   kubectl ate get workers -n workshop       # ws holds no worker
   ```
   Lab 4 lets the gateway's idle policy do this step for you; here you do it by hand so the timing is yours.
   A session waiting for a human costs a 37 MB object in the bucket and nothing else.
3. The human comes back. The approval is an ADK function response on the same session:
   ```bash
   curl -s -N -X POST -H 'Content-Type: application/json' localhost:8081/adk/ws/run_sse -d '{
     "appName":"workspace","userId":"u1","sessionId":"'$S'",
     "newMessage":{"role":"user","parts":[{"functionResponse":{"id":"'$REQ'","name":"adk_request_confirmation","response":{"confirmed":true}}}]}}' \
     | sed -n 's/^data: //p' | jq -c '{author, fr: [.content.parts[]?.functionResponse.response // empty], text: [.content.parts[]?.text // empty]}'
   ```
   The router parked the request, resumed the actor, and ADK ran `publish_report`; the response names the
   file under `/workspace/published/`. Measured while building the lab: 2.6 s from approval to publication,
   suspend included. [`adk/scripts/drill-confirm.sh ws`](../../scripts/drill-confirm.sh) runs the three steps with timing.

## Part B: Worker loss with no plan

Substrate forwards SIGTERM to an actor's main process when its worker pod goes away: a node drain, a
`WorkerPool` roll, a Spot reclaim. Nothing else happens. Substrate does not suspend the actor; it gives the
process a window (30 minutes on a normal worker, 15 seconds on Spot) and expects something to call
`SuspendActor` with `--mode=sync` before it closes. A process that exits on SIGTERM, which is what
uvicorn, gunicorn and node do by default, cannot be suspended.

`adk-exit-v1` is `adk-v1` with the shim told to behave that way (`SHIM_EXIT_ON_SIGTERM=1`).

4. Create the template and an actor. Give it a turn, suspend it synchronously (that is the durable snapshot),
   give it a second turn, then delete the worker pod under it:
   ```bash
   scripts/render.sh adk/manifests/template-adk-exit-v1.yaml.tmpl | kubectl ate create actor-template -f -
   until kubectl ate get actor-template adk-exit-v1 -a workshop -o json 2>/dev/null | jq -e '.status.goldenSnapshotStatus | (.goldenTag.name // .errorMessage)' >/dev/null; do sleep 3; done
   kubectl ate create actor fragile --template=adk-exit-v1 -a workshop
   make egress POLICY=adk/manifests/egress-adk.yaml ACTOR=fragile
   adk/scripts/turn.sh fragile "Remember the word pelican. Reply with: noted"
   kubectl ate suspend actor fragile -a workshop --mode=sync
   adk/scripts/turn.sh fragile "Also remember the word osprey. Reply with: noted"
   adk/scripts/drill-evict.sh fragile
   ```
   The trace ends in `ACTOR_STATE_CRASHED` a few seconds after the delete. The worker pod is gone, the
   process with it, and everything since the last durable snapshot.
5. Resume refuses a crashed actor. Revert it to that snapshot and ask what it remembers:
   ```bash
   adk/scripts/turn.sh fragile "Which words did I ask you to remember?"      # 503: AssignWorker prerequisite not met
   kubectl ate revert actor fragile -a workshop
   adk/scripts/turn.sh fragile "Which words did I ask you to remember?"
   kubectl ate suspend actor fragile -a workshop                              # free its worker for Parts C and D
   ```
   Pelican is back, osprey is gone: the actor is exactly as it was at the `--mode=sync` suspend. The durable
   snapshot is the unit of loss, which is why every Substrate example suspends before it relies on state.

## Part C: Worker loss with a plan

`ws` runs the same image with the default shim. The shim is PID 1
([`shim/entrypoint.py`](../../app/shim/entrypoint.py)): it starts `adk api_server` as a child and, on
SIGTERM, stays alive, reads its own actor name from the `actorMetadata` volume at `/run/ate`, and asks the
gateway to suspend it: `POST /actors/ws/suspend`. The gateway calls `SuspendActor` with
`DURABILITY_MODE_SYNCHRONOUS` ([`frontdoor/adk.go`](../../../app/internal/frontdoor/adk.go)).

6. Give `ws` a turn so it is RUNNING, then delete its worker pod and follow the gateway:
   ```bash
   adk/scripts/turn.sh ws "Remember the word heron. Reply with: noted"
   adk/scripts/drill-evict.sh ws
   kubectl -n workshop logs deploy/gateway --since=2m | grep self-suspend
   adk/scripts/turn.sh ws "What word did I ask you to remember?"
   kubectl ate get actor ws -a workshop                                      # a different WORKER POD
   ```
   Expected: `SUSPENDED` about 3 s after the delete, a gateway line like
   `self-suspend workshop/ws: SUSPENDED with a durable snapshot in 1.4s`, and `heron` from the new worker.

Two details in that code path cost a day each while this workshop was built. Read them before you write
your own harness:

- **The suspend must outlive the caller's connection.** The first gateway ran `SuspendActor` on the HTTP
  request's context. The checkpoint cuts the sandbox's network within milliseconds, so the actor's
  connection dropped, Go cancelled the context, and ateapi logged
  `workflow failed at step CallAteletSuspend: context canceled`. The worker then exited and the actor was
  CRASHED, exactly as in Part B. The fix is a 202 and `context.WithoutCancel`: the caller is the process
  about to be frozen; it can never receive the answer.
- **In-memory flags survive snapshots.** The first shim set a `_sigterm_seen` boolean before asking for the
  suspend. After the restore on another worker, the boolean was still true, so the next eviction was
  ignored and the actor sat RUNNING on a Terminating pod for its whole grace period. A restored process is
  the same process; anything it remembers about shutting down is stale. The shim now checks whether the
  request thread is alive instead.

## Part D: Eviction in the middle of a turn, and ADK's part of the deal

7. Start a 20 s tool call, evict the worker while it runs, then let ADK finish the turn:
   ```bash
   adk/scripts/drill-midturn.sh ws
   ```
   Read the output in order. The actor went SUSPENDED in about 3 s and resumed elsewhere; the platform kept
   the process. The client's stream ended early (the connection broke at the checkpoint). The session
   history shows the shell tool's response as `{"error": "Invocation was aborted by client."}`: ADK cancels
   a turn whose SSE client is gone, so the tool was abandoned, not finished.
8. The drill's last step is ADK's side of the recovery. The app is resumable, so a `/run_sse` request with the
   original `invocationId` and no message replays the event log from the last event and re-executes the
   interrupted tool; the drill sends exactly this:
   ```json
   {"appName":"workspace","userId":"u1","sessionId":"<session>","invocationId":"<id of the cut turn>"}
   ```
   The `sleep 20 && echo` runs again and the turn completes with its output. Do this right after the cut: once
   later turns are appended to the session, the model treats the old invocation as history and summarises it
   instead of re-running the tool. Note what the replay means: ADK resume **replays**, Substrate restore does
   not. A tool that sends an email or charges a card must be idempotent, or gated behind a confirmation as
   in Part A, before you combine the two.

## What just happened

| Interruption | Without a plan | With the shim and gateway |
|---|---|---|
| Human away for a day | worker held, or state lost if you kill the pod | SUSPENDED; 37 MB in the bucket; approval resumes in under 3 s |
| Worker pod deleted between turns | CRASHED; revert to the last durable snapshot | SUSPENDED in about 3 s; next turn on another worker |
| Worker pod deleted mid-tool | CRASHED | SUSPENDED; the turn is cut by ADK; `invocationId` resume re-runs the tool |
| Spot reclaim (15 s) | CRASHED | the same path, if the sync suspend fits in the window: 1.4 s here for a 37 MB snapshot |

- Substrate's contract is narrow and documented: SIGTERM, a window, and `SuspendActor`. Everything else is the harness's job.
- The unit of loss is the last durable snapshot. `--mode=sync` after a turn is the cheapest insurance there is.
- Two layers, two resume mechanisms: Substrate restores a process; ADK replays an invocation. Design tools for both.

## Checkpoint

```bash
make adk-verify LAB=3
```

**Stuck?** Run `make adk-catch-up LAB=4`.

Next: [Density, parking and idle](../04-density/README.md)
