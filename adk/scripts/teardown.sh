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

# make adk-teardown [YES=1]: delete what the ADK track created, keep the cluster and the official
# workshop resources. Run the official `make teardown` afterwards for the rest.
#   - actors and templates adk-*, their egress policies (deleted with the actors)
#   - the adk-agents worker pool
#   - the Agent Sandbox lab namespace (claims, pools, templates, snapshots) and its storage config
#   - the workshop-secrets namespace (the Gemini key copy); the API key itself stays in the project
set -euo pipefail
source "$(dirname "$0")/../../scripts/lib.sh"
load_env

if [[ -z "${YES:-}" ]]; then
  read -r -p "Delete every ADK actor and template in atespace $ATESPACE, the adk-agents pool, sandbox-lab and workshop-secrets? [y/N] " a
  [[ "$a" == y || "$a" == Y ]] || die "aborted"
fi

step "ADK actors and templates"
for t in $(kubectl ate get actor-templates -a "$ATESPACE" -o json 2>/dev/null | jq -r 'if type=="array" then . else (.actorTemplates // .items // []) end | .[].metadata.name' | grep '^adk-' || true); do
  reset_template "$ATESPACE" "$t" && ok "deleted template $t and its actors"
done

step "ADK worker pool"
kubectl -n "$NAMESPACE" delete workerpool adk-agents --ignore-not-found >/dev/null && ok "adk-agents deleted"

step "Agent Sandbox lab"
if kubectl get ns sandbox-lab >/dev/null 2>&1; then
  kubectl -n sandbox-lab delete sandboxclaims,sandboxwarmpools,sandboxtemplates,podsnapshotmanualtriggers --all --ignore-not-found >/dev/null 2>&1 || true
  kubectl -n sandbox-lab delete podsnapshots --all --ignore-not-found >/dev/null 2>&1 || true
  kubectl delete ns sandbox-lab --wait=false >/dev/null && ok "sandbox-lab deleting"
fi
kubectl delete podsnapshotstorageconfig adk-snapshots --ignore-not-found >/dev/null 2>&1 || true

step "Secrets namespace"
kubectl delete ns workshop-secrets --ignore-not-found --wait=false >/dev/null && ok "workshop-secrets deleting"

ok "ADK track resources removed. Left in place: the cluster, the GKE Sandbox node pool, the snapshot bucket, the API key, the official workshop resources (make teardown)."
