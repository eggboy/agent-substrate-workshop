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

# make adk-catch-up LAB=<1-5> [RESET=1]: bring the environment to the start of an ADK lab.
# Like scripts/catch-up.sh for the core modules: creates what is missing, never re-does a lab's
# drills. RESET=1 deletes and recreates the templates the previous lab created, with their actors.
#
# Start of lab N means the end state of lab N-1:
#   1  official modules 0 to 4 done, ADK image built, ADK worker pool, gateway with the ADK routes,
#      the Gemini key in workshop-secrets/gemini and the credential provider allowing the atespace
#   2  + template adk-v1, actor ws with the approach-A policy
#   3  + template adk-vertex-v1, actor wsv with the approach-B policy
#   4  + template adk-exit-v1 and actor fragile (lab 3 drills are not replayed)
#   5  + actors ws-01 to ws-20 with the policy, idle-suspend at 5s
set -euo pipefail
source "$(dirname "$0")/../../scripts/lib.sh"
load_env
N="${LAB:-}"
[[ "$N" =~ ^[1-5]$ ]] || die "usage: make adk-catch-up LAB=<1-5> [RESET=1]"
ADK="$REPO_ROOT/adk"
RENDER="$REPO_ROOT/scripts/render.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

render_to() { "$RENDER" "$1" >"$TMP/$2"; echo "$TMP/$2"; }

template() { # <name> <tmpl-file>: create (or RESET) a template and wait for its golden snapshot
  local name="$1" file="$2"
  if [[ -n "${RESET:-}" ]] && kubectl ate get actor-template "$name" -a "$ATESPACE" >/dev/null 2>&1; then
    step "RESET=1: deleting template $name and its actors"
    reset_template "$ATESPACE" "$name"
  fi
  ensure_template "$ATESPACE" "$name" "$(render_to "$ADK/manifests/$file" "$name.yaml")"
  ok "template $name ready"
}

actor() { # <name> <template> <policy-file>
  # RESET=1 (or a template move in lab 6) can leave the actor on another template: recreate it.
  local have
  have="$(actor_json "$ATESPACE" "$1" 2>/dev/null | jq -r '.actorTemplate.name // empty' || true)"
  if [[ -n "$have" && "$have" != "$2" ]]; then
    kubectl ate delete actor "$1" -a "$ATESPACE" >/dev/null 2>&1 || true
    wait_for 120 "actor $1 to be deleted" bash -c "! kubectl ate get actor '$1' -a '$ATESPACE' >/dev/null 2>&1"
  fi
  ensure_actor "$ATESPACE" "$1" "$2"
  "$REPO_ROOT/scripts/egress.sh" apply "$ADK/manifests/$3" "--actor=$1" >/dev/null
  ok "actor $1 ($2) with $3"
}

step "ADK lab $N: foundations"
require_state agent-image "make build-agent (official module 2)"
require_state worker-image "make install"
[[ -s "$STATE_DIR/adk-image" ]] || "$ADK/scripts/build-image.sh"
kubectl get ns "$NAMESPACE" >/dev/null 2>&1 || "$RENDER" "$REPO_ROOT/modules/02-hello-actor/manifests/workerpool.yaml.tmpl" | kubectl apply -f - >/dev/null
"$RENDER" "$ADK/manifests/workerpool.yaml.tmpl" | kubectl apply -f - >/dev/null
ensure_atespace "$ATESPACE"
kubectl -n "$NAMESPACE" get deploy gateway >/dev/null 2>&1 || "$REPO_ROOT/scripts/build.sh" gateway >/dev/null
kubectl -n "$NAMESPACE" get deploy gateway >/dev/null 2>&1 || "$REPO_ROOT/scripts/gateway.sh" >/dev/null
if ! kubectl -n workshop-secrets get secret gemini >/dev/null 2>&1; then
  die "Secret workshop-secrets/gemini is missing. Create it from a Gemini Developer API key restricted to generativelanguage.googleapis.com:
  kubectl create namespace workshop-secrets
  kubectl -n workshop-secrets create secret generic gemini --from-literal=key=\"\$(gcloud services api-keys get-key-string <KEY_NAME> --format='value(keyString)')\""
fi
if ! kubectl -n ate-system get configmap k8s-credential-provider-namespace-policy -o jsonpath='{.data.namespace-policy\.yaml}' | grep -q "atespace: $ATESPACE"; then
  step "allowing atespace $ATESPACE to read workshop-secrets (credential provider policy)"
  kubectl -n ate-system get configmap k8s-credential-provider-namespace-policy -o jsonpath='{.data.namespace-policy\.yaml}' \
    | awk -v as="$ATESPACE" '/^policies: \[\]$/ {print "policies:"; print "- atespace: " as; print "  allowedNamespaces: [workshop-secrets]"; next} {print}' >"$TMP/policy.yaml"
  grep -q "atespace: $ATESPACE" "$TMP/policy.yaml" || die "could not add atespace $ATESPACE to the credential provider policy; edit the ConfigMap by hand (optional lab J, step 3)"
  kubectl -n ate-system create configmap k8s-credential-provider-namespace-policy --from-file=namespace-policy.yaml="$TMP/policy.yaml" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl -n ate-system rollout restart deploy/k8s-credential-provider >/dev/null
  kubectl -n ate-system rollout status deploy/k8s-credential-provider --timeout=120s >/dev/null
fi
ok "foundations in place"
# Idle policy per lab: 30 s keeps two workers flowing between actors in labs 1, 2 and 4; lab 3
# suspends actors itself and needs it off; lab 4's exercise turns it to 5 s (lab 5 start).
set_idle() {
  local want="$1" have
  have="$(kubectl -n "$NAMESPACE" get deploy gateway -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="IDLE_AFTER")].value}' 2>/dev/null || true)"
  [[ "$have" == "$want" ]] && return 0
  if [[ "$want" == 0s ]]; then "$REPO_ROOT/scripts/idle.sh" off >/dev/null; else IDLE_AFTER="$want" "$REPO_ROOT/scripts/idle.sh" on >/dev/null; fi
  ok "gateway idle-suspend: IDLE_AFTER=$want"
}
case "$N" in
  1|2|4) set_idle 30s ;;
  3)     set_idle 0s
         # With the idle policy off, two RUNNING actors would hold both ADK workers for the whole lab.
         for a in $(_actors_list "$ATESPACE" | jq -r '.[] | select((.status.state // "") == "ACTOR_STATE_RUNNING" and ((.actorTemplate.name // "") | startswith("adk-"))) | .metadata.name'); do
           kubectl ate suspend actor "$a" -a "$ATESPACE" >/dev/null 2>&1 && ok "suspended $a (lab 3 starts with free workers)"
         done ;;
  5)     set_idle "${IDLE_AFTER:-5s}" ;;
esac
(( N >= 2 )) || { ok "ready for ADK lab 1"; exit 0; }

step "ADK lab 1 state"
template adk-v1 template-adk-v1.yaml.tmpl
actor ws adk-v1 egress-adk.yaml
(( N >= 3 )) || { ok "ready for ADK lab 2"; exit 0; }

step "ADK lab 2 state"
template adk-vertex-v1 template-adk-vertex-v1.yaml.tmpl
actor wsv adk-vertex-v1 egress-adk-vertex.yaml
(( N >= 4 )) || { ok "ready for ADK lab 3"; exit 0; }

step "ADK lab 3 state"
template adk-exit-v1 template-adk-exit-v1.yaml.tmpl
actor fragile adk-exit-v1 egress-adk.yaml
if [[ "$(actor_state "$ATESPACE" fragile)" == CRASHED ]]; then
  kubectl ate revert actor fragile -a "$ATESPACE" >/dev/null && ok "reverted fragile"
fi
(( N >= 5 )) || { ok "ready for ADK lab 4"; exit 0; }

step "ADK lab 4 state"
for i in $(seq -w 1 20); do
  ensure_actor "$ATESPACE" "ws-$i" adk-v1
  "$REPO_ROOT/scripts/egress.sh" apply "$ADK/manifests/egress-adk.yaml" "--actor=ws-$i" >/dev/null
done
ok "ws-01 to ws-20 with egress-adk.yaml (wsv keeps its own policy)"
ok "ready for ADK lab 5"
