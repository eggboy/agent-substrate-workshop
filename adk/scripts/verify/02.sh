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

# make adk-verify LAB=2: the end state of "Egress and credentials".
set -uo pipefail
source "$(dirname "$0")/common.sh"
step "verify ADK lab 2 (egress and credentials)"

check "gateway port-forward is up" gateway_up
# Approach A: the policy injects the key, and the template never holds one.
check "ws egress policy names the credential URI, not a key" bash -c "kubectl ate get egress-policy ws -a '$ATESPACE' -o yaml | grep -q 'ate-secret://k8s.io/default/workshop-secrets/gemini/key'"
check "template adk-v1 carries only the placeholder key" bash -c "kubectl ate get actor-template adk-v1 -a '$ATESPACE' -o yaml | grep -q 'placeholder-replaced-by-egress-gateway'"
check "the credential provider allows atespace $ATESPACE to read workshop-secrets" bash -c "kubectl -n ate-system get configmap k8s-credential-provider-namespace-policy -o jsonpath='{.data.namespace-policy\.yaml}' | grep -q 'atespace: $ATESPACE'"
check "ws (approach A) completes a model turn" adk_turn_ok ws "Reply with one word: alpha"

# Approach B: the Vertex proxy route exists, wsv has no HTTPS rule, and the gateway attributes its calls.
check "template adk-vertex-v1 has a golden snapshot" _template_ready "$ATESPACE" adk-vertex-v1
check "actor wsv exists" actor_json "$ATESPACE" wsv
check "wsv egress policy has no https rule (no internet at all)" bash -c "! kubectl ate get egress-policy wsv -a '$ATESPACE' -o yaml | grep -q 'https:'"
check "wsv egress policy injects an actor JWT" bash -c "kubectl ate get egress-policy wsv -a '$ATESPACE' -o yaml | grep -q 'actorJwt'"
check "wsv (approach B) completes a model turn through /genai" adk_turn_ok wsv "Reply with one word: beta"
check "gateway log attributes a Vertex call to actor/$ATESPACE/wsv" bash -c "kubectl -n '$NAMESPACE' logs deploy/gateway --since=10m | grep -q 'vertex-proxy actor=actor/$ATESPACE/wsv'"
finish 2
