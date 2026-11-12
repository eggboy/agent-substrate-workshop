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

# make adk-verify LAB=5: the end state of "Like-for-like with Agent Sandbox on GKE".
set -uo pipefail
source "$(dirname "$0")/common.sh"
step "verify ADK lab 5 (Agent Sandbox leg)"
ns=sandbox-lab

check "a GKE Sandbox (gVisor) node exists" bash -c "kubectl get nodes -l sandbox.gke.io/runtime=gvisor --no-headers | grep -q ."
check "Agent Sandbox controller is running" kubectl -n agent-sandbox-system rollout status deploy/agent-sandbox-controller --timeout=10s
check "PodSnapshotStorageConfig adk-snapshots is Ready" bash -c "kubectl get podsnapshotstorageconfig adk-snapshots -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}' | grep -q True"
check "PodSnapshotPolicy adk-policy exists" kubectl -n "$ns" get podsnapshotpolicy adk-policy
check "SandboxTemplate adk-template admits the lab client and allows DNS" bash -c "kubectl -n $ns get sandboxtemplate adk-template -o json | jq -e '(.spec.networkPolicy.ingress | length) >= 1 and ([.spec.networkPolicy.egress[].ports[]?.port] | index(53)) != null' >/dev/null"
check "Secret gemini copied into $ns" kubectl -n "$ns" get secret gemini
check "warm pool adk-pool has a ready sandbox" bash -c "[[ \"\$(kubectl -n $ns get sandboxwarmpool adk-pool -o jsonpath='{.status.readyReplicas}')\" -ge 1 ]]"
check "at least one PodSnapshot reached Ready (the drill ran)" bash -c "kubectl -n $ns get podsnapshots -o json | jq -e '[.items[] | select(.status.conditions[]? | select(.type==\"Ready\" and .status==\"True\"))] | length >= 1' >/dev/null"
check "a claimed sandbox has been resumed (operatingMode Running after a suspend)" bash -c "kubectl -n $ns get sandboxes -o json | jq -e '[.items[] | select(.spec.operatingMode==\"Running\")] | length >= 1' >/dev/null"
finish 5
