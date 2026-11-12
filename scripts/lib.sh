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

# Shared helpers for workshop scripts. Source this file; do not execute it.
# Not for your own terminal: it turns on `set -euo pipefail` and its helpers `exit` on error, which would
# close an interactive shell, and it's bash-only. This guard is POSIX so zsh reads it before anything else.
case $- in *i*)
  echo "scripts/lib.sh is for the workshop's scripts. In your own shell (bash or zsh), run: source scripts/env.sh" >&2
  return 1 ;;
esac
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_DIR="${WORKSHOP_STATE_DIR:-$REPO_ROOT/.workshop}"
# Your shell's PATH before we prepend bin/, so checks can tell whether *you* can type `kubectl ate`.
# Exported once, so a script run by another script still sees the original.
: "${WORKSHOP_USER_PATH:=$PATH}"; export WORKSHOP_USER_PATH
export PATH="$REPO_ROOT/bin:$PATH"

if [[ -t 1 ]]; then C_B=$'\e[1m'; C_G=$'\e[32m'; C_Y=$'\e[33m'; C_R=$'\e[31m'; C_0=$'\e[0m'; else C_B=; C_G=; C_Y=; C_R=; C_0=; fi
step() { echo "${C_B}==> $*${C_0}"; }
ok()   { echo "${C_G}  ✓ $*${C_0}"; }
warn() { echo "${C_Y}  ! $*${C_0}" >&2; }
die()  { echo "${C_R}  ✗ $*${C_0}" >&2; exit 1; }

# load_env reads workshop.env (auto-exporting every variable) and checks the essentials.
load_env() {
  local f="${WORKSHOP_ENV_FILE:-$REPO_ROOT/workshop.env}"
  [[ -f "$f" ]] || die "missing $f — run: cp workshop.env.example workshop.env and set PROJECT_ID and CLUSTER_LOCATION"
  # A MOCK_LLM you pass on the command line (MOCK_LLM=true make …) beats workshop.env. Captured once and
  # exported, so a script run by another script still sees what you typed, not workshop.env's value.
  : "${WORKSHOP_MOCK_LLM_OVERRIDE=${MOCK_LLM:-}}"; export WORKSHOP_MOCK_LLM_OVERRIDE
  set -a; # shellcheck disable=SC1090
  source "$f"; set +a
  if [[ -n "$WORKSHOP_MOCK_LLM_OVERRIDE" ]]; then MOCK_LLM="$WORKSHOP_MOCK_LLM_OVERRIDE"; fi
  [[ -n "${PROJECT_ID:-}" ]] || die "PROJECT_ID is empty in $f"
  : "${NAMESPACE:=workshop}" "${ATESPACE:=workshop}" "${MOCK_LLM:=false}"
  export NAMESPACE ATESPACE MOCK_LLM
  # The ADK templates render ${GEMINI_MODEL}; keep the same default as scripts/gateway.sh.
  : "${GEMINI_MODEL:=gemini-3.8-flash}"; export GEMINI_MODEL
  # Substrate's ate-setup reads CLUSTER_NAME / CLUSTER_LOCATION (and fails without them when PROJECT_ID is
  # set). Older workshop.env files used CLUSTER / ZONE_OR_REGION; accept those too. CLUSTER_LOCATION has no
  # default on purpose: a zonal cluster (us-central1-a) is not found under its region (us-central1), so
  # scripts that talk to the cluster call require_cluster_location instead of guessing.
  : "${CLUSTER_NAME:=${CLUSTER:-ate-cluster}}" "${CLUSTER_LOCATION:=${ZONE_OR_REGION:-}}"
  export CLUSTER_NAME CLUSTER_LOCATION
  # ko (and ate-setup's docker buildx build) target the cluster's nodes, not your laptop. GKE nodes here
  # are amd64; set KO_DEFAULTPLATFORMS=linux/arm64 in workshop.env for an Arm (e.g. C4A/Axion) cluster.
  : "${KO_DEFAULTPLATFORMS:=linux/amd64}"; export KO_DEFAULTPLATFORMS
  mkdir -p "$STATE_DIR"
}

# require_cluster_location: fail with the command that tells you the value.
require_cluster_location() {
  [[ -n "${CLUSTER_LOCATION:-}" ]] || die "CLUSTER_LOCATION is empty in workshop.env — set it to your cluster's zone or region (the LOCATION column of: gcloud container clusters list --project $PROJECT_ID)"
}

# install_running: true while a background install (make install-bg) is alive. Checks the pid file's
# process is still install-substrate.sh, so a recycled pid doesn't count.
install_running() {
  local pid
  pid="$(cat "$STATE_DIR/install.pid" 2>/dev/null)" || return 1
  [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null && ps -o command= -p "$pid" 2>/dev/null | grep -q 'install-substrate\.sh'
}

# user_has_ate: true if your shell (not just our scripts) finds kubectl-ate, or already has bin/ on PATH.
user_has_ate() {
  local p IFS=:
  for p in $WORKSHOP_USER_PATH; do [[ "${p%/}" == "$REPO_ROOT/bin" ]] && return 0; done
  env PATH="$WORKSHOP_USER_PATH" sh -c 'command -v kubectl-ate' >/dev/null 2>&1
}
path_hint() {
  warn "kubectl ate is not on your shell's PATH. Run this (and add it to ~/.zshrc, ~/.bashrc or .envrc):"
  echo "    export PATH=\"$REPO_ROOT/bin:\$PATH\"" >&2
}
# open_hint <port>: how to open a port-forwarded UI in your browser. In Cloud Shell, localhost is the Cloud Shell
# VM rather than your laptop, so the browser gets there through Web Preview.
open_hint() {
  if [[ "${CLOUD_SHELL:-}" == true ]]; then
    echo "open it with Web Preview (top right of Cloud Shell) > Change port > $1"
  else
    echo "open http://localhost:$1"
  fi
}

state_put() { mkdir -p "$STATE_DIR"; printf '%s\n' "$2" >"$STATE_DIR/$1"; }
state_get() { [[ -f "$STATE_DIR/$1" ]] && cat "$STATE_DIR/$1"; }
# require_state <file> <make target>: fail with the command that produces the file.
require_state() { [[ -s "$STATE_DIR/$1" ]] || die ".workshop/$1 is missing — run: $2"; }

# wait_for <timeout-seconds> <description> <command...>: retry every 2s until the command succeeds.
wait_for() {
  local timeout="$1" what="$2"; shift 2
  local deadline=$((SECONDS + timeout))
  until "$@" >/dev/null 2>&1; do
    (( SECONDS >= deadline )) && die "timed out after ${timeout}s waiting for: $what"
    sleep 2
  done
}

# render <template> <VAR...>: envsubst restricted to the named variables, which must be set.
render() {
  local tmpl="$1"; shift
  local v list=""
  for v in "$@"; do
    [[ -n "${!v:-}" ]] || die "render $tmpl: \$$v is not set"
    list+="\${$v} "
  done
  envsubst "$list" <"$tmpl"
}

# _port_listening <port>: true if something accepts connections on localhost:<port>. Uses bash's /dev/tcp, so it
# needs no nc (Cloud Shell doesn't ship one).
_port_listening() { (: <"/dev/tcp/localhost/$1") >/dev/null 2>&1; }
# _port_holder <port>: "pid N: command" of whatever listens on the port, if lsof can tell.
_port_holder() {
  local pid
  pid="$(lsof -t -iTCP:"$1" -sTCP:LISTEN 2>/dev/null | head -1)" || true
  [[ -n "$pid" ]] && echo "pid $pid: $(ps -o command= -p "$pid" 2>/dev/null)"
}

# port_forward <name> <namespace> <resource> <local-port> <remote-port>
# Reuses a live forward we started, restarts a dead one, refuses a port owned by someone else.
port_forward() {
  local name="$1" ns="$2" res="$3" lport="$4" rport="$5"
  local pidf="$STATE_DIR/pf-$name.pid"
  if [[ -f "$pidf" ]] && kill -0 "$(cat "$pidf")" 2>/dev/null; then
    _port_listening "$lport" && return 0
    kill "$(cat "$pidf")" 2>/dev/null || true
  fi
  rm -f "$pidf"
  if _port_listening "$lport"; then
    local holder; holder="$(_port_holder "$lport")" || true
    die "port $lport is in use by another process${holder:+ ($holder)}; stop it or free the port. A port-forward from another workshop checkout points at that checkout's cluster: run \`make stop-forwards\` there"
  fi
  kubectl -n "$ns" port-forward "$res" "$lport:$rport" >"$STATE_DIR/pf-$name.log" 2>&1 &
  echo $! >"$pidf"
  wait_for 20 "port-forward $name on :$lport" _port_listening "$lport"
}

# stop_port_forward <name>: stop one forward we started (no-op if it isn't running).
stop_port_forward() {
  local pidf="$STATE_DIR/pf-$1.pid" pid i
  [[ -f "$pidf" ]] || return 0
  pid="$(cat "$pidf")"
  kill "$pid" 2>/dev/null || true
  for ((i = 0; i < 20; i++)); do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.05
  done
  rm -f "$pidf"
}

stop_port_forwards() {
  local f n
  for f in "$STATE_DIR"/pf-*.pid; do
    [[ -f "$f" ]] || continue
    n="${f##*/pf-}"; stop_port_forward "${n%.pid}"
  done
}

# --- Substrate helpers (idempotent) ---

ensure_atespace() {
  kubectl ate get atespace "$1" >/dev/null 2>&1 || kubectl ate create atespace "$1"
  ensure_gateway_access "$1" "${NAMESPACE:-workshop}"
}

# ensure_gateway_access <atespace> [namespace]: grant the gateway's ServiceAccount editor on the atespace
# once the atespace exists (v0.6.0+ enforces OpenFGA authorization by default).
ensure_gateway_access() {
  local as="${1:-$ATESPACE}" ns="${2:-${NAMESPACE:-workshop}}"
  kubectl ate get atespace "$as" >/dev/null 2>&1 || return 0
  kubectl ate get access-policy -a "$as" -o json 2>/dev/null | grep -q "user:system:serviceaccount:${ns}:gateway" && return 0
  kubectl ate create access-policy -a "$as" -f - >/dev/null 2>&1 <<EOF || true
bindings:
  - role: editor
    members:
      - user:system:serviceaccount:${ns}:gateway
EOF
}

# ensure_template <atespace> <name> <rendered-yaml-file>: create once, then wait for the golden snapshot.
ensure_template() {
  local as="$1" name="$2" file="$3"
  kubectl ate get actor-template "$name" -a "$as" >/dev/null 2>&1 || kubectl ate create actor-template -f "$file"
  wait_for 600 "golden snapshot for template $as/$name" _template_ready "$as" "$name"
}
_template_ready() {
  kubectl ate get actor-template "$2" -a "$1" -o json | jq -e '.status.goldenSnapshotStatus.goldenTag.name' >/dev/null
}

ensure_actor() {
  local as="$1" name="$2" template="$3"
  actor_json "$as" "$name" >/dev/null 2>&1 || kubectl ate create actor "$name" --template="$template" -a "$as"
}

actor_json()   { kubectl ate get actor "$2" -a "$1" -o json; }
# actor_state strips the ACTOR_STATE_ prefix (e.g. ACTOR_STATE_RUNNING -> RUNNING) so
# callers can compare against bare RUNNING/SUSPENDED.
actor_state()  { actor_json "$1" "$2" | jq -r '.status.state // "UNKNOWN"' | sed 's/^ACTOR_STATE_//'; }
actor_worker() { actor_json "$1" "$2" | jq -r '.status.workerAssignment.workerPod // ""'; }

# router_curl <actor> [curl args...]: talk to an actor through a port-forwarded atenet-router.
router_curl() {
  local actor="$1" port="${ROUTER_LOCAL_PORT:-8080}"; shift
  port_forward router ate-system svc/atenet-router "$port" 80
  curl -sS --max-time 90 -H "ate-target-actor: ${ATESPACE}/${actor}" "$@"
}

_actor_in_state() { [[ "$(actor_state "$1" "$2")" == "$3" ]]; }

# suspend_actor <atespace> <name>: checkpoint a running actor and wait until it is SUSPENDED.
suspend_actor() {
  local as="$1" name="$2"
  if [[ "$(actor_state "$as" "$name")" == RUNNING ]]; then
    kubectl ate suspend actor "$name" -a "$as" >/dev/null
  fi
  wait_for 120 "actor $as/$name to be SUSPENDED" _actor_in_state "$as" "$name" SUSPENDED
}

# _actors_list <atespace>: the actor list as a JSON array, whatever envelope kubectl ate uses.
_actors_list() {
  kubectl ate get actors -a "$1" -o json | jq -c 'if type == "array" then . else (.actors // .items // []) end'
}
actor_names() { _actors_list "$1" | jq -r '.[].metadata.name'; }
# template_actors <atespace> <template>: names of the actors (any state) created from that template.
template_actors() {
  _actors_list "$1" | jq -r --arg t "$2" '.[] | select((.actorTemplate.name // "") == $t) | .metadata.name'
}
_no_template_actors() { [[ -z "$(template_actors "$1" "$2")" ]]; }
_template_gone() { ! kubectl ate get actor-template "$2" -a "$1" >/dev/null 2>&1; }
# _delete_template succeeds once the template is gone; ateapi refuses the delete while actors still use it.
_delete_template() {
  _template_gone "$1" "$2" || kubectl ate delete actor-template "$2" -a "$1" >/dev/null 2>&1 || true
  _template_gone "$1" "$2"
}

# reset_template <atespace> <template>: delete the template and every actor made from it, in any
# state, so it can be recreated. A golden snapshot is immutable, so this is the only way to fix one.
reset_template() {
  local as="$1" t="$2" a
  for a in $(template_actors "$as" "$t"); do
    kubectl ate delete actor "$a" -a "$as" >/dev/null || warn "could not delete actor $as/$a"
  done
  wait_for 180 "actors of template $as/$t to finish deleting" _no_template_actors "$as" "$t"
  wait_for 120 "template $as/$t to be deleted" _delete_template "$as" "$t"
}

# count_actors_in_state <atespace> <STATE> [name-prefix]
count_actors_in_state() {
  _actors_list "$1" | jq --arg s "$2" --arg p "${3:-}" \
    '[.[] | select(((.status.state // "") | sub("^ACTOR_STATE_"; "")) == $s and (.metadata.name | startswith($p)))] | length'
}

# gateway_chat <actor> <message>: one chat turn through the gateway's front door.
# Prints the JSON body, then the HTTP status code on its own last line.
gateway_chat() {
  local port="${GATEWAY_LOCAL_PORT:-8081}"
  port_forward gateway "$NAMESPACE" svc/gateway "$port" 80
  curl -sS --max-time 150 -H 'Content-Type: application/json' -w '\n%{http_code}\n' \
    -d "$(jq -cn --arg m "$2" '{message: $m}')" "http://localhost:$port/chat/$1"
}
