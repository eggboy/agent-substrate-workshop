# Lab 6: Observe and operate (15 min)

Official module 6 against the ADK fleet, plus the day-2 operation every agent platform needs: a new
template version for actors that already exist.

## Steps

1. **Metrics.** The gateway exports the ADK routes next to the chat metrics; the Prometheus UI and the
   console dashboards from module 6 work unchanged (`make observe`, `make prometheus-ui`). With Lab 4's load
   running in a second terminal (`DURATION=180 CONCURRENCY=2 adk/scripts/load.sh`), query:
   - `sum by (outcome) (rate(workshop_adk_requests_total[2m]))`: ADK requests proxied, by outcome
   - `sum by (outcome) (rate(workshop_idle_suspends_total[2m]))`: idle suspends
   - `sum by (outcome) (increase(workshop_self_suspends_total[1h]))`: evictions the shim turned into suspends (Lab 3)
   - `histogram_quantile(0.95, sum by (le, "ate.actor.operation.name") (rate({"ate.actor.lifecycle.operation.duration_bucket"}[5m])))`: resume and suspend latency from Substrate itself
2. **One actor across workers.** `kubectl ate logs` follows the actor, not the Pod:
   ```bash
   kubectl ate logs actor ws -a workshop --source=lifecycle | tail -20
   kubectl ate logs actor ws -a workshop -f | grep -v '"message":"[IW][01]'     # the shim and ADK lines only
   ```
   In Logs Explorer, the actor's whole history across Pods: `jsonPayload.actor="workshop/ws"` with the cluster
   filter from module 6, step 7. Look for the `self-suspend` line from the gateway and the `Actor checkpointing`
   line from the worker in the same minute: that pair is an eviction handled.
3. **A new template version.** Templates are immutable; the day-2 move is a new one and `kubectl ate update actor`.
   `adk-v2` ([template-adk-v2.yaml.tmpl](../../manifests/template-adk-v2.yaml.tmpl)) differs from `adk-v1` in one
   line: ADK sessions go to a SQLite file on `/workspace` instead of process memory. First, put something in
   both places on `ws`:
   ```bash
   adk/scripts/turn.sh ws "Remember the word cormorant and write it to /workspace/bird.txt. Reply with: noted"
   scripts/render.sh adk/manifests/template-adk-v2.yaml.tmpl | kubectl ate create actor-template -f -
   until kubectl ate get actor-template adk-v2 -a workshop -o json 2>/dev/null | jq -e '.status.goldenSnapshotStatus | (.goldenTag.name // .errorMessage)' >/dev/null; do sleep 2; done
   ```
4. **Move the actor.** An actor must be SUSPENDED to change template. After the move it cold-boots from
   `adk-v2`'s golden snapshot (that snapshot's memory, not the actor's) with its own `/workspace`:
   ```bash
   kubectl ate suspend actor ws -a workshop --mode=sync
   kubectl ate update actor ws --template=adk-v2 -a workshop
   adk/scripts/turn.sh ws "What word did I ask you to remember, and what is in /workspace/bird.txt? One line."
   ```
   The file is there; the word is not. Memory belonged to the old process, the durable directory belongs to the
   actor. From now on `ws`'s sessions are rows in `/workspace/sessions.db`, and the next template move keeps them:
   ```bash
   adk/scripts/turn.sh ws "Remember the word gannet. Reply with: noted" s2
   kubectl ate suspend actor ws -a workshop --mode=sync
   kubectl ate get actor ws -a workshop -o json | jq '.status.snapshots[-1] | {fidelity, generation}'
   adk/scripts/turn.sh ws "What word did I ask you to remember? One word." s2
   ```
5. **Checkpoints with tags** (optional lab D applies unchanged): `kubectl ate create tag before-publish --actor ws -a workshop`
   before a risky tool call, `kubectl ate create actor ws-copy --template=adk-v2 --tag before-publish -a workshop` to
   fork the session, `kubectl ate revert actor` to go back.

## What just happened

- Nothing in the ADK agent was instrumented. Substrate's lifecycle metrics and the gateway's counters are enough to
  see resumes, suspends, evictions and ADK traffic per outcome.
- A template upgrade is a controlled cold boot: plan where session state lives before day 2. `memory://` is the
  fastest and survives suspend and resume; it does not survive a template change. SQLite on `durableDir` survives
  both and costs a few milliseconds per event.

## Checkpoint

```bash
make adk-verify LAB=6
```

Next: [Wrap-up](../../../modules/07-wrap-up/README.md)
