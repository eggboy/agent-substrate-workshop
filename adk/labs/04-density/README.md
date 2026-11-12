# Lab 4: Density, parking and idle (35 min)

Twenty ADK sessions, two workers. This lab measures the two numbers that size a Substrate
deployment and shows the knob between them: how many sessions can exist, and how many can be
active at once.

## The arithmetic first

A worker is a Pod with a CPU and memory limit (`adk-agents`: 2 CPU, 2 GiB). An actor declares what it
needs (`adk-v1`: 1 CPU, 1.5 GiB). Substrate places a RUNNING actor on a worker with room; a SUSPENDED
actor is a 37 MB object in the bucket and occupies nothing. So:

- sessions that exist: bounded by the bucket, in practice by your budget for snapshots;
- sessions active at the same instant: bounded by workers times actors per worker (here 2 x 1).

A request for a suspended actor when every worker is full does not fail: atenet-router parks it for up to
60 s (the workshop raises the default 5 s) until a worker frees up. Workers free up when something suspends
an actor. In this workshop that something is the gateway's idle policy: `IDLE_AFTER` seconds after an
actor's last request, the gateway calls `SuspendActor` (asynchronous: the snapshot stays on the node and
uploads later).

## Steps

1. Twenty actors from `adk-v1`, the policy on all of them, idle-suspend at 5 s (`make adk-catch-up LAB=5` does the same):
   ```bash
   source scripts/env.sh
   for i in $(seq -w 1 20); do kubectl ate create actor ws-$i --template=adk-v1 -a workshop >/dev/null; done
   make egress POLICY=adk/manifests/egress-adk.yaml ALL=1
   make idle-on IDLE_AFTER=5s
   kubectl ate get actors -a workshop | awk 'NR>1 {print $4}' | sort | uniq -c      # 20+ SUSPENDED, 0 workers used
   ```
2. Two clients, random actors, one model call per turn, 150 s. In a second terminal watch the workers:
   ```bash
   watch -n 2 'kubectl ate get workers -n workshop; kubectl -n workshop logs deploy/gateway --since=20s | grep idle-suspend | tail -3'
   ```
   ```bash
   DURATION=150 CONCURRENCY=2 adk/scripts/load.sh
   ```
   The summary splits turns by whether the actor had to be resumed. Measured while building the lab:
   31 turns, 0 failures, 16 distinct actors served by 2 workers; resumed turns p50 3.0 s, p95 5.7 s; warm turns 2.0 s.
3. Read the `first_request` column for resumed turns: p50 5.7 s. That is not the restore. The restore is
   1.1 s (Lab 1). The rest is waiting for a worker: both are busy, and the idle policy frees one 5 s after
   its actor's last request. Prove it by changing the knob and running again:
   ```bash
   make idle-on IDLE_AFTER=1s
   DURATION=150 CONCURRENCY=2 adk/scripts/load.sh
   ```
   Resumed `first_request` drops by about 4 s; the price is a suspend after every turn (1.5 s of worker time
   each, and a snapshot upload). Pick the number for your traffic, not the smallest one.
4. More clients than workers:
   ```bash
   DURATION=120 CONCURRENCY=4 adk/scripts/load.sh
   ```
   Measured: 34 turns, 3 failed, resumed `first_request` p95 29 s. Four conversations want two workers;
   requests park, and past 60 s they fail. This is the honest limit: suspended sessions are free, active
   ones are not. The remedy is more workers, not a smaller `IDLE_AFTER`:
   ```bash
   kubectl -n workshop patch workerpool adk-agents --type merge -p '{"spec":{"replicas":4}}'
   kubectl ate get workers -n workshop                                     # four, after the Pods start
   DURATION=120 CONCURRENCY=4 adk/scripts/load.sh
   ```
5. What a suspended fleet costs. With the load finished and the idle policy on:
   ```bash
   sleep 10; kubectl ate get workers -n workshop                           # 0 actors on every worker
   gcloud storage du -sh gs://${BUCKET_NAME}/atespaces/workshop/actors/     # about 37 MB per actor that ever ran
   ```
6. The Go agent from the morning for comparison: its snapshot is about 1 MB and its resume 0.25 s. Python with
   google-genai and the ADK server is 37 MB and 0.2 to 1.2 s. Both fit the router's parking budget with room to
   spare; the ADK number is the one to use for sizing a real fleet.

## Sizing from this

| Input | Where it comes from | Here |
|---|---|---|
| Peak concurrent active sessions | your traffic, p99 not average | 2 clients: 2; 4 clients: 4 |
| Actors per worker | worker limits / actor limits | 1 (2 GiB / 1.5 GiB) |
| Workers | ceil(peak / actors per worker) | 2 or 4 |
| Idle policy | the gap you accept before a session pays a resume | 5 s here, minutes in production |
| Snapshot storage | sessions x snapshot size | 20 x 37 MB |

The always-on-agent reference measured a 47:1 modelled ratio of sessions to peak concurrent actors for a
real assistant workload; your ratio is whatever your p99 says. The lab's point is that the two bounds are
different quantities with different knobs.

## Checkpoint

```bash
make adk-verify LAB=4
```

**Stuck?** Run `make adk-catch-up LAB=5`.

Next: [Like-for-like with Agent Sandbox on GKE](../05-agent-sandbox/README.md)
