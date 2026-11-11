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

# render.sh <file.tmpl>: print the template with every ${VAR} filled from workshop.env or .workshop/ state.
# Usage: scripts/render.sh modules/02-hello-actor/manifests/template.yaml.tmpl | kubectl ate create actor-template -f -
source "$(dirname "$0")/lib.sh"
load_env
tmpl="${1:?usage: render.sh <file.tmpl>}"
[[ -f "$tmpl" ]] || die "no such template: $tmpl"

# state_source <VAR>: "<state file>|<make target>" for variables that come from .workshop/.
state_source() {
  case "$1" in
    AGENT_IMAGE)   echo "agent-image|make build-agent" ;;
    GATEWAY_IMAGE) echo "gateway-image|make gateway" ;;
    WORKER_IMAGE)  echo "worker-image|make install" ;;
    ADK_IMAGE)     echo "adk-image|make adk-image" ;;
    *) return 1 ;;
  esac
}

vars=()
while IFS= read -r v; do vars+=("$v"); done < <(grep -oE '\$\{[A-Z_][A-Z0-9_]*\}' "$tmpl" | tr -d '${}' | sort -u)
# Bash 3.2 (macOS) treats "${vars[@]}" as unbound under set -u when vars has zero
# elements, so every use is guarded by a length check instead of relying on the
# expansion alone.
if (( ${#vars[@]} > 0 )); then
  for v in "${vars[@]}"; do
    if [[ -z "${!v:-}" ]] && src="$(state_source "$v")"; then
      require_state "${src%%|*}" "${src#*|}"
      printf -v "$v" '%s' "$(state_get "${src%%|*}")"
      export "${v?}"
    fi
  done
  render "$tmpl" "${vars[@]}"
else
  cat "$tmpl"
fi
