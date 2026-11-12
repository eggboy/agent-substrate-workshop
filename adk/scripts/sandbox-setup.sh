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

# make adk-sandbox-setup: the pre-event provisioning for Lab 5 (Agent Sandbox on GKE with Pod
# snapshots), on the workshop cluster from workshop.env. Idempotent; every step is skipped when
# its resource exists. Needs the Pod snapshots feature on the cluster: pass --enable-pod-snapshots
# at creation, or run `gcloud container clusters update $CLUSTER_NAME --enable-pod-snapshots`.
#
#   SANDBOX_MACHINE_TYPE=n2-standard-4 SANDBOX_NODES=1 AGENT_SANDBOX_VERSION=v1.0.6 make adk-sandbox-setup
#
# Creates: node pool sandbox-pool (GKE Sandbox, gVisor), bucket gs://${PROJECT_ID}-sandbox-snaps
# (hierarchical namespace, no soft delete) with managed folder snapshots/, custom IAM role
# podSnapshotGcsReadWriter, IAM bindings for ns sandbox-lab / KSA snapshot-sa and the GKE robot,
# the Agent Sandbox controller. The manifests themselves are applied in the lab
# (adk/manifests/agent-sandbox.yaml.tmpl).
set -euo pipefail
source "$(dirname "$0")/../../scripts/lib.sh"
load_env
require_cluster_location

machine="${SANDBOX_MACHINE_TYPE:-n2-standard-4}"
nodes="${SANDBOX_NODES:-1}"
version="${AGENT_SANDBOX_VERSION:-v1.0.6}"
bucket="gs://${PROJECT_ID}-sandbox-snaps"
project_number="$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')"
pool_id="projects/${project_number}/locations/global/workloadIdentityPools/${PROJECT_ID}.svc.id.goog"

step "Pod snapshots on cluster $CLUSTER_NAME"
if gcloud container clusters describe "$CLUSTER_NAME" --location "$CLUSTER_LOCATION" --project "$PROJECT_ID" --format=json | grep -q '"podSnapshotsConfig"\|enablePodSnapshots\|podSnapshot'; then
  ok "pod snapshots look enabled"
else
  warn "could not confirm --enable-pod-snapshots on the cluster; if the PodSnapshot CRDs are missing, run: gcloud container clusters update $CLUSTER_NAME --location $CLUSTER_LOCATION --enable-pod-snapshots"
fi

step "GKE Sandbox node pool sandbox-pool ($machine x $nodes)"
if gcloud container node-pools describe sandbox-pool --cluster "$CLUSTER_NAME" --location "$CLUSTER_LOCATION" --project "$PROJECT_ID" >/dev/null 2>&1; then
  ok "node pool exists"
else
  # Shielded and private-node flags match the workshop cluster recipe for projects with the
  # usual org policies (no external IPs, Shielded VMs required).
  gcloud container node-pools create sandbox-pool --cluster "$CLUSTER_NAME" --location "$CLUSTER_LOCATION" --project "$PROJECT_ID" \
    --machine-type "$machine" --num-nodes "$nodes" --sandbox type=gvisor \
    --enable-private-nodes --shielded-secure-boot --shielded-integrity-monitoring --workload-metadata=GKE_METADATA --quiet
  ok "node pool created"
fi

step "Snapshot bucket $bucket"
if gcloud storage buckets describe "$bucket" --project "$PROJECT_ID" >/dev/null 2>&1; then
  ok "bucket exists"
else
  gcloud storage buckets create "$bucket" --project "$PROJECT_ID" --location "$REGION" \
    --uniform-bucket-level-access --enable-hierarchical-namespace --soft-delete-duration=0d
  ok "bucket created"
fi
gcloud storage managed-folders describe "$bucket/snapshots/" >/dev/null 2>&1 || gcloud storage managed-folders create "$bucket/snapshots/" >/dev/null
ok "managed folder snapshots/"

step "IAM: custom role and bindings"
if ! gcloud iam roles describe podSnapshotGcsReadWriter --project "$PROJECT_ID" >/dev/null 2>&1; then
  gcloud iam roles create podSnapshotGcsReadWriter --project "$PROJECT_ID" \
    --permissions=storage.objects.get,storage.objects.create,storage.objects.delete,storage.folders.create --quiet >/dev/null
  ok "role podSnapshotGcsReadWriter created (new roles take a minute to become bindable)"
fi
bind() { # <member> <role>
  local i
  for i in 1 2 3 4 5 6; do
    if gcloud storage buckets add-iam-policy-binding "$bucket" --member="$1" --role="$2" >/dev/null 2>&1; then return 0; fi
    sleep 10
  done
  die "could not bind $2 to $1 on $bucket"
}
bind "principalSet://iam.googleapis.com/${pool_id}/namespace/sandbox-lab" roles/storage.bucketViewer
bind "principal://iam.googleapis.com/${pool_id}/subject/ns/sandbox-lab/sa/snapshot-sa" "projects/${PROJECT_ID}/roles/podSnapshotGcsReadWriter"
bind "principal://iam.googleapis.com/${pool_id}/subject/ns/sandbox-lab/sa/snapshot-sa" roles/storage.objectUser
bind "serviceAccount:service-${project_number}@container-engine-robot.iam.gserviceaccount.com" roles/storage.objectUser
ok "bindings in place"

step "Agent Sandbox controller $version"
kubectl apply -f "https://github.com/kubernetes-sigs/agent-sandbox/releases/download/${version}/sandbox-with-extensions.yaml" >/dev/null
kubectl -n agent-sandbox-system rollout status deploy/agent-sandbox-controller --timeout=180s >/dev/null
ok "controller running"

step "Lab 5 manifests and the model key"
"$REPO_ROOT/scripts/render.sh" "$REPO_ROOT/adk/manifests/agent-sandbox.yaml.tmpl" | kubectl apply -f - >/dev/null
if kubectl -n workshop-secrets get secret gemini >/dev/null 2>&1; then
  kubectl -n workshop-secrets get secret gemini -o json \
    | jq 'del(.metadata.namespace,.metadata.uid,.metadata.resourceVersion,.metadata.creationTimestamp,.metadata.managedFields)' \
    | kubectl apply -n sandbox-lab -f - >/dev/null
  ok "Secret gemini copied into sandbox-lab"
else
  warn "workshop-secrets/gemini is missing (make adk-catch-up LAB=1 explains how to create it); copy it into sandbox-lab afterwards"
fi
wait_for 600 "warm pool adk-pool to have a ready sandbox" bash -c "[[ \"\$(kubectl -n sandbox-lab get sandboxwarmpool adk-pool -o jsonpath='{.status.readyReplicas}' 2>/dev/null)\" -ge 1 ]]"
ok "Lab 5 is ready: adk/scripts/drill-sandbox.sh"
