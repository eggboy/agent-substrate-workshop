# Lab 5: Like-for-like with Agent Sandbox on GKE (40 min)

Same image, same agent, same prompts, same timing script, the other GKE runtime for agents.
Agent Sandbox on GKE runs one Pod per sandbox on a GKE Sandbox (gVisor) node pool, and GKE Pod
snapshots checkpoint a Pod to Cloud Storage and restore it. By the end you have a table of your own
numbers next to the Substrate ones from Labs 1 to 4, and a view of what each system asks of you.

The protocol is deliberately boring: claim, two turns, snapshot, suspend, resume, memory check,
every step timed. [`adk/scripts/drill-sandbox.sh`](../../scripts/drill-sandbox.sh) runs it; read it first,
it is the whole lab in 120 lines.

## Setup (done before the event, listed so you know what is there)

- A node pool with `--sandbox type=gvisor` (n2-standard-4; Pod snapshots do not support E2). Substrate workers
  never land there: GKE taints these nodes with `sandbox.gke.io/runtime`.
- The cluster was created with `--enable-pod-snapshots`, a bucket with hierarchical namespace, a custom IAM role
  for the sandbox's Kubernetes service account, and the Agent Sandbox controller v1.0.6 (`sandbox-with-extensions.yaml`).
- [`adk/manifests/agent-sandbox.yaml.tmpl`](../../manifests/agent-sandbox.yaml.tmpl): `PodSnapshotStorageConfig`,
  `PodSnapshotPolicy` (manual trigger, grouped per sandbox), a `SandboxTemplate` with the ADK image, and a
  `SandboxWarmPool` of one. Compare the template with `adk-v1`:

  | | `adk-v1` (Substrate) | `adk-template` (Agent Sandbox) |
  |---|---|---|
  | Unit | actor record, placed on shared workers | one Pod per sandbox, full PodSpec |
  | Model key | injected at egress; placeholder in the sandbox | `GOOGLE_API_KEY` from a Secret: in the Pod and in every snapshot |
  | SIGTERM | the shim asks for a suspend | `SHIM_EXIT_ON_SIGTERM=1`; there is nobody to ask |
  | Network in | atenet-router, by actor name | a managed NetworkPolicy admitting only a `sandbox-router` the release manifest does not install; the lab opens ingress from a client Pod |
  | Network out | deny all, allowlist by hostname | public IPs only, and **no DNS** until a port-53 rule is added |
  | Snapshot trigger | `SuspendActor` | `PodSnapshotManualTrigger`, then `operatingMode: Suspended` |
  | Wake | any request | `operatingMode: Running`, then the client reconnects |

## Steps

1. Apply the manifests and wait for the warm pool (first time on a node: image pull, about a minute):
   ```bash
   source scripts/env.sh
   scripts/render.sh adk/manifests/agent-sandbox.yaml.tmpl | kubectl apply -f -
   kubectl get secret gemini -n workshop-secrets -o json | jq 'del(.metadata.namespace,.metadata.uid,.metadata.resourceVersion,.metadata.creationTimestamp,.metadata.managedFields)' | kubectl apply -n sandbox-lab -f -
   kubectl wait sandboxwarmpool adk-pool -n sandbox-lab --for=jsonpath='{.status.readyReplicas}'=1 --timeout=600s
   kubectl -n sandbox-lab get pods -o wide
   ```
   Note the second line: the key has to be copied into the sandbox namespace as a Secret. That is the first
   difference, and it is not a small one.
2. Run the protocol:
   ```bash
   adk/scripts/drill-sandbox.sh
   ```
   Measured while building the lab (n2-standard-4, image cached): claim ready **1.7 s**; snapshot trigger Complete
   3.8 s, `PodSnapshot` Ready **4.7 s**, about **144 MiB** per snapshot; suspend (Pod deleted) **1.4 s**; resume:
   Sandbox Ready 2.2 s, ADK `/health` answering **3.3 s** after the patch; the session and `/workspace/notes.md`
   both restored; turn after resume 2.8 s.
3. Look at what the drill had to do to talk to the sandbox, because a harness would have to do the same:
   ```bash
   kubectl -n sandbox-lab get networkpolicy -o yaml | grep -A12 'ingress:'
   kubectl -n sandbox-lab get pod adk-jump -o jsonpath='{.spec.containers[0].args}'; echo
   ```
   `kubectl port-forward` cannot reach a gVisor Pod (it dials the Pod's loopback, which gVisor's netstack does
   not serve), so the drill creates a Service keyed on the sandbox's own label and a socat Pod. Substrate's
   equivalent is `ate-target-actor: workshop/ws` on any request.
4. Repeat the resume without a Ready snapshot to see the failure mode. Suspend, delete the latest `PodSnapshot`,
   resume: the Pod comes back as a fresh process with an empty session.
   ```bash
   SB=$(kubectl -n sandbox-lab get sandboxclaim -o jsonpath='{.items[-1].status.sandbox.name}')
   kubectl -n sandbox-lab patch sandbox $SB --type=merge -p '{"spec":{"operatingMode":"Suspended"}}'
   kubectl -n sandbox-lab delete podsnapshot --all
   kubectl -n sandbox-lab patch sandbox $SB --type=merge -p '{"spec":{"operatingMode":"Running"}}'
   kubectl wait sandbox $SB -n sandbox-lab --for=condition=Ready --timeout=300s
   ```
   Nothing in Agent Sandbox snapshots for you; the harness decides when. Substrate's idle policy in Lab 4 is
   the same decision, made in one place for every actor.
5. Fill the table with your numbers:

   | Measure | Substrate (your Labs 1 to 4) | Agent Sandbox (this lab) |
   |---|---|---|
   | Fresh session to first answer | | |
   | Snapshot taken and durable | | |
   | Snapshot size | | |
   | Suspend | | |
   | Resume to first byte | | |
   | Who triggers the wake | the request | |
   | Eviction of the host mid-session | | |
   | Where the model key lives | | |
   | What you had to add for networking | | |

## What just happened

Both runtimes checkpoint a gVisor sandbox and restore it in seconds; the raw numbers are close (0.2 to 1.2 s
against 3.3 s to wake, 37 MB against 144 MiB). The difference is in who does the work:

- **Wake path.** Substrate wakes an actor because a request arrived and parks the request meanwhile. Agent
  Sandbox needs a controller or client to patch the Sandbox and reconnect.
- **Eviction.** Substrate hands the process a SIGTERM and a window, and the shim turns that into a durable
  snapshot. An Agent Sandbox Pod that is deleted takes the state since the last manual snapshot with it.
- **Credentials and network.** Substrate's egress gateway keeps the key out of the sandbox and resolves names
  itself. Agent Sandbox's defaults are a Secret in the Pod and a policy with no DNS and no entry point.
- **Fit.** GKE's own guidance holds: Agent Sandbox for continuously active agents, GPUs, Autopilot, Arm, or
  a full PodSpec; Substrate for many stateful CPU agents that are idle most of the time.

## Checkpoint

```bash
make adk-verify LAB=5
```

Next: [Observe and operate](../06-observe/README.md)
