#!/usr/bin/env bash
# Copyright 2026 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# The Agent Sandbox leg of the like-for-like comparison: claim a sandbox running the ADK image,
# talk to it, snapshot it, suspend it, resume it, and check that it remembers. Every step is
# timed with the same turn.sh the Substrate leg uses.
#
#   adk/scripts/drill-sandbox.sh            (expects adk/manifests/agent-sandbox.yaml.tmpl applied)
set -euo pipefail

ns=sandbox-lab
claim="adk-claim-$(date +%s)"
here="$(cd "$(dirname "$0")" && pwd)"
port="${SANDBOX_PORT:-8082}"
export ADK_BASE_URL="http://localhost:$port"
now_ms() { date +%s%3N; }

forward() { # (re)start the port-forward to the jump pod, wait until the sandbox answers through it
  pkill -f "port-forward pod/adk-jump $port:8080" 2>/dev/null || true
  kubectl -n "$ns" port-forward pod/adk-jump "$port:8080" >/dev/null 2>&1 &
  for _ in $(seq 1 120); do curl -sf "$ADK_BASE_URL/health" >/dev/null 2>&1 && return 0; sleep 0.5; done
  echo "the sandbox never answered /health through the jump pod" >&2; return 1
}

# kubectl port-forward dials 127.0.0.1 inside the Pod's network namespace, which a gVisor
# sandbox does not serve (its netstack owns the Pod IP, not the host loopback). So the drill
# reaches the sandbox the way a client in the cluster would: a Service selecting the sandbox's
# own label (stable across suspend and resume, when the Pod is re-created) and a plain socat
# Pod that port-forward can reach.
reachability() {
  local hash
  hash="$(kubectl -n "$ns" get pod "$sandbox" -o jsonpath='{.metadata.labels.agents\.x-k8s\.io/sandbox-name-hash}')"
  kubectl apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Service
metadata: {name: $sandbox, namespace: $ns}
spec:
  selector: {agents.x-k8s.io/sandbox-name-hash: "$hash"}
  ports: [{port: 80, targetPort: 80}]
---
apiVersion: v1
kind: Pod
metadata: {name: adk-jump, namespace: $ns}
spec:
  containers:
  - name: socat
    image: alpine/socat
    args: ["tcp-listen:8080,fork,reuseaddr", "tcp-connect:$sandbox.$ns.svc.cluster.local:80"]
EOF
  kubectl -n "$ns" wait pod/adk-jump --for=condition=Ready --timeout=120s >/dev/null
}

echo "== 1. claim a sandbox from the warm pool"
kubectl wait sandboxwarmpool adk-pool -n "$ns" --for=jsonpath='{.status.readyReplicas}'=1 --timeout=600s >/dev/null
t0=$(now_ms)
kubectl apply -f - >/dev/null <<EOF
apiVersion: extensions.agents.x-k8s.io/v1beta1
kind: SandboxClaim
metadata: {name: $claim, namespace: $ns}
spec:
  warmPoolRef: {name: adk-pool}
EOF
kubectl wait sandboxclaim "$claim" -n "$ns" --for=condition=Ready --timeout=300s >/dev/null
sandbox="$(kubectl get sandboxclaim "$claim" -n "$ns" -o jsonpath='{.status.sandbox.name}')"
echo "claim ready in $(( $(now_ms) - t0 )) ms: sandbox=$sandbox node=$(kubectl -n "$ns" get pod "$sandbox" -o jsonpath='{.spec.nodeName}')"
reachability
forward

echo "== 2. two turns (memory + file), then a snapshot"
"$here/turn.sh" "$sandbox" "Reply with exactly one word: ready" s1 2>&1 | tail -2
"$here/turn.sh" "$sandbox" "Create /workspace/notes.md containing the line: sandbox leg ok. Then say done." s1 2>&1 | tail -2
t0=$(now_ms)
kubectl apply -f - >/dev/null <<EOF
apiVersion: podsnapshot.gke.io/v1
kind: PodSnapshotManualTrigger
metadata: {name: $claim, namespace: $ns}
spec:
  targetPod: $sandbox
EOF
for _ in $(seq 1 300); do
  st="$(kubectl get podsnapshotmanualtrigger "$claim" -n "$ns" -o jsonpath='{.status.conditions[?(@.type=="Triggered")].reason}' 2>/dev/null || true)"
  [[ "$st" == Complete ]] && break; sleep 0.5
done
t_trigger=$(( $(now_ms) - t0 ))
snap="$(kubectl get podsnapshotmanualtrigger "$claim" -n "$ns" -o jsonpath='{.status.snapshotCreated.name}')"
kubectl wait podsnapshot "$snap" -n "$ns" --for=condition=Ready --timeout=600s >/dev/null
t_ready=$(( $(now_ms) - t0 ))
echo "snapshot: trigger Complete in ${t_trigger} ms, PodSnapshot Ready in ${t_ready} ms, name=$snap"
gcloud storage du -s --readable-sizes "gs://$(kubectl get podsnapshotstorageconfig adk-snapshots -o jsonpath='{.spec.snapshotStorageConfig.gcs.bucket}')/snapshots" 2>/dev/null || true
echo "pod after snapshot (postCheckpoint: resume): $(kubectl -n "$ns" get pod "$sandbox" -o jsonpath='{.status.phase}')"
forward >/dev/null
"$here/turn.sh" "$sandbox" "Reply with one word: still-here" s1 2>&1 | tail -1

echo "== 3. suspend (operatingMode: Suspended deletes the Pod)"
t0=$(now_ms)
kubectl patch sandbox "$sandbox" -n "$ns" --type=merge -p '{"spec":{"operatingMode":"Suspended"}}' >/dev/null
kubectl wait pod "$sandbox" -n "$ns" --for=delete --timeout=180s >/dev/null 2>&1 || true
echo "pod gone in $(( $(now_ms) - t0 )) ms"

echo "== 4. resume (operatingMode: Running restores from the latest Ready snapshot)"
t0=$(now_ms)
kubectl patch sandbox "$sandbox" -n "$ns" --type=merge -p '{"spec":{"operatingMode":"Running"}}' >/dev/null
kubectl wait sandbox "$sandbox" -n "$ns" --for=condition=Ready --timeout=300s >/dev/null
t_sbready=$(( $(now_ms) - t0 ))
forward >/dev/null
t_health=$(( $(now_ms) - t0 ))
"$here/turn.sh" "$sandbox" "What word did I ask you to reply with first, and what does /workspace/notes.md contain? One line." s1 2>&1 | tail -2
echo "resume: Sandbox Ready in ${t_sbready} ms, ADK /health answering in ${t_health} ms, turn done in $(( $(now_ms) - t0 )) ms"
kubectl -n "$ns" get pod "$sandbox" -o custom-columns='POD:.metadata.name,NODE:.spec.nodeName,RESTORED:.metadata.annotations.podsnapshot\.gke\.io/restored-from' 2>/dev/null || true
pkill -f "port-forward pod/adk-jump $port:8080" 2>/dev/null || true
kubectl -n "$ns" delete pod adk-jump service "$sandbox" --ignore-not-found >/dev/null 2>&1 || true
