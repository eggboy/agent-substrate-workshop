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

# Confirmation across a suspend: the agent asks a human before publishing, the actor is
# suspended while the human thinks, and the approval lands on a resumed actor.
#
#   adk/scripts/drill-confirm.sh <actor> [session] [user]
#
# Step 1 asks the agent to write and publish a report; publish_report requires confirmation,
# so the stream ends with an `adk_request_confirmation` function call (and no publication).
# Step 2 suspends the actor synchronously. Step 3 answers the confirmation with
# `{"confirmed": true}`, which resumes the actor and runs the tool. The script checks that a
# publish_report function response arrived and that the published file exists.
set -euo pipefail

actor="${1:?usage: drill-confirm.sh <actor> [session] [user]}"
session="${2:-confirm-$(date +%s)}"
user="${3:-u1}"
app="${ADK_APP:-workspace}"
atespace="${ATESPACE:-workshop}"
base="${GATEWAY_URL:-http://localhost:8081}/adk/$actor"

run_sse() { # $1 = new_message JSON; prints the raw SSE stream
  local msg="$1"
  local body
  body="$(jq -cn --arg app "$app" --arg user "$user" --arg session "$session" --argjson msg "$msg" \
    '{appName:$app, userId:$user, sessionId:$session, streaming:false, newMessage:$msg}')"
  curl -sS -N -X POST -H 'Content-Type: application/json' -d "$body" "$base/run_sse"
}
events() { sed -n 's/^data: //p' | tr -d '\r'; }

curl -sS -o /dev/null -X POST -H 'Content-Type: application/json' -d '{}' "$base/apps/$app/users/$user/sessions/$session"

echo "== 1. ask for a publication (publish_report needs confirmation)"
step1="$(run_sse '{"role":"user","parts":[{"text":"Create /workspace/report.md containing one line: lab 3 report. Then publish it with publish_report. Do not ask me anything, just call the tools."}]}' | events)"
request_id="$(jq -r '.content.parts[]? | select(.functionCall.name=="adk_request_confirmation") | .functionCall.id' <<<"$step1" | head -1)"
if [[ -z "$request_id" ]]; then
  echo "no adk_request_confirmation in the stream:" >&2
  jq -c '{author, fc: [.content.parts[]?.functionCall.name], text: [.content.parts[]?.text]}' <<<"$step1" >&2
  exit 1
fi
published_before="$(jq -r '.content.parts[]? | select(.functionResponse.name=="publish_report") | .functionResponse.response.status' <<<"$step1" | head -1)"
echo "confirmation requested: id=$request_id (publish_report ran before approval: ${published_before:-no})"

echo "== 2. suspend the actor while the human decides"
t0=$(date +%s%3N)
kubectl ate suspend actor "$actor" -a "$atespace" --mode=sync >/dev/null 2>&1
echo "suspended in $(( $(date +%s%3N) - t0 )) ms; state=$(kubectl ate get actor "$actor" -a "$atespace" -o json 2>/dev/null | jq -r .status.state)"

echo "== 3. approve (resumes the actor, runs the tool)"
approval="$(jq -cn --arg id "$request_id" '{role:"user", parts:[{functionResponse:{id:$id, name:"adk_request_confirmation", response:{confirmed:true}}}]}')"
t0=$(date +%s%3N)
step3="$(run_sse "$approval" | events)"
elapsed=$(( $(date +%s%3N) - t0 ))
status="$(jq -r '.content.parts[]? | select(.functionResponse.name=="publish_report") | .functionResponse.response.status' <<<"$step3" | head -1)"
published_path="$(jq -r '.content.parts[]? | select(.functionResponse.name=="publish_report") | .functionResponse.response.published_path // empty' <<<"$step3" | head -1)"
jq -r '.content.parts[]? | select(.text) | .text' <<<"$step3" | tail -2
echo "approval turn: ${elapsed} ms, publish_report status=${status:-none} path=${published_path:-none}"
echo "actor now: $(kubectl ate get actor "$actor" -a "$atespace" -o json 2>/dev/null | jq -r .status.state)"
[[ "$status" == success ]]
