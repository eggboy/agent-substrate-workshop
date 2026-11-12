# ADK track: instructor notes

Companion to [`instructor/runbook.md`](../instructor/runbook.md) and
[`instructor/troubleshooting.md`](../instructor/troubleshooting.md) for the ADK labs. Everything below was
hit while building the track on the reference environment; the timings are from those runs.

## Timings to expect (reference environment)

| Operation | Time | Notes |
|---|---|---|
| `make adk-image` (Cloud Build) | 1 to 2 min | `uv sync --frozen` from the lock; the lock must point at pypi.org |
| Golden snapshot of `adk-v1` | 20 to 30 s | needs a free ADK worker; 34 MB |
| `make adk-catch-up LAB=4 RESET=1` | 2 min | three templates, three actors |
| First request to a new actor | 1.1 s (7 s the first time on a node) | the 7 s is the one-time snapshot pull per node |
| Text turn / tool turn | 2 to 4 s / 10 to 15 s | `gemini-3.8-flash`, one or several model calls |
| `suspend --mode=sync` | 2.4 to 2.9 s | async: about 1.5 s |
| Eviction to SUSPENDED (shim path) | 2.7 to 3.4 s | gateway log: `self-suspend ... in 1.2s` |
| `drill-confirm.sh` | 25 s | two model turns and a sync suspend |
| `drill-midturn.sh` | 75 s | includes a 20 s tool call twice |
| `drill-sandbox.sh` | 90 s | warm pool must be ready first |
| `load.sh` DURATION=150 | 2.5 min | summary at the end; the sampler prints every 10 s |

## Cut lines, in order

1. Lab 2 approach B becomes a demo from the instructor's terminal (saves 8 min).
2. Lab 3 Part B (crash and revert) becomes a demo (saves 6 min); keep Part C, it is the point of the lab.
3. Lab 4 steps 3 and 4 (the `IDLE_AFTER` change and four clients) are skipped; quote the numbers (saves 10 min).
4. Lab 5 step 4 (resume without a snapshot) is skipped (saves 3 min).
5. Lab 6 becomes a demo (saves 10 min).

## Things that go wrong, and what to say

**"no worker has room for the actor" (503 after about 60 s).** Two ADK workers, and two actors already
RUNNING with idle-suspend off. The attendee ran `make idle-off` for Lab 3 and moved on, or is talking to a
third actor. `kubectl ate suspend actor <other> -a workshop`, or `make idle-on IDLE_AFTER=30s` outside Lab 3.
The verify scripts suspend other ADK actors before they test one.

**The model refuses a prompt.** `gemini-3.8-flash` declines to print `$GOOGLE_API_KEY`, to curl
`169.254.169.254`, and to probe `gateway.workshop.svc.cluster.local`. The labs only ask for external probes.
If an attendee rewrites a prompt and gets a refusal, that is the model, not the sandbox.

**A turn takes 100 s or more.** Open-ended prompts ("append a line to a file") become 10 to 20 model calls as
the agent verifies its work. The density prompts are one model call on purpose. Also check the ADK shell tool's
30 s timeout: a command that sleeps longer is killed with `Command timed out after 30s`.

**Part A of Lab 3 publishes nothing (`status: error`).** `publish_report` refuses a path that is not a file in
`/workspace`. The drill writes `report.md` first; a hand-typed prompt must too.

**Part D's resume summarises instead of re-running the tool.** The `invocationId` resume must be the next
request after the cut turn. Once more turns are appended, the model treats the aborted invocation as history.

**`fragile` ends SUSPENDED instead of CRASHED in Part B.** Idle-suspend was on; the gateway suspended it before the
eviction. `make idle-off`, then `turn.sh fragile` again before `drill-evict.sh`.

**Cloud Shell: `kubectl` says "the server has asked for the client to provide credentials" while `gcloud auth
print-access-token` works.** A stale cached token. `mv ~/.config/gcloud/access_tokens.db{,.bak}; rm -f
~/.kube/gke_gcloud_auth_plugin_cache` and retry. Seen once after about 30 hours of sessions.

**Cloud Build fails with `Failed to download graphviz`** or any package from an internal mirror. The `uv.lock`
was generated on a machine with a corporate index. Regenerate it on Cloud Shell: `cd adk/app && rm uv.lock && uv lock`.

**Agent Sandbox: every turn takes exactly 20 s and answers nothing.** DNS is blocked by the managed
NetworkPolicy; the template in this repo adds the port-53 rule. Check with
`kubectl -n sandbox-lab exec <pod> -- curl -sS -m 5 https://generativelanguage.googleapis.com/`.

**Agent Sandbox: `kubectl port-forward` to the sandbox Pod says "connection refused".** gVisor Pods do not
serve the host loopback. Use the drill's Service plus socat Pod, or the sandbox-router.

**ssh to Cloud Shell drops with exit 255 as soon as a command runs.** The command line contained
`pkill -f <pattern>` and the pattern matched the login shell's own argv. Put the `pkill` in a script file.

## The two defects worth telling as stories

Both are in Lab 3 Part C. Tell them in this order and with the log lines, they land better than any slide.

1. `workflow failed at step CallAteletSuspend: context canceled` in the ate-api-server log, 6 ms after the
   checkpoint started. The gateway had run the suspend on the actor's HTTP request context; the checkpoint cut
   the actor's network; Go cancelled the context; the worker exited; the actor was CRASHED. Fix: 202 and
   `context.WithoutCancel`.
2. `SIGTERM again: suspend already requested, still waiting` in the shim's log on an actor that had been
   restored on a new worker hours earlier. The flag was set in the previous incarnation's memory and came back
   with the snapshot. Fix: dedupe on a live thread, not on a boolean.

## Environment facts (reference project)

Org policies: no external IPs, Shielded VMs required, no `default` network. The cluster recipe needs
`--enable-private-nodes --enable-dns-access --no-enable-ip-access --shielded-secure-boot
--shielded-integrity-monitoring --enable-ip-alias`, a subnet with a Cloud NAT, and a maintenance exclusion
(`no_minor_or_node_upgrades`) to satisfy `make preflight` on a release channel. c3-standard-4 was out of stock
in one zone; try the next one. The GKE Sandbox node pool (n2-standard-4) needs the same shielded and private flags.
