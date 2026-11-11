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

# make adk-image — builds adk/app (the ADK actor image) with Cloud Build and records the
# digest-pinned reference in .workshop/adk-image, the same contract scripts/build.sh keeps for
# the Go images. Cloud Build instead of ko: this is a Python image with a Dockerfile, and
# Cloud Shell has no Docker daemon worth relying on.
set -euo pipefail
source "$(cd "$(dirname "$0")/../.." && pwd)/scripts/lib.sh"
load_env

repo="${KO_DOCKER_REPO:?KO_DOCKER_REPO must be set in workshop.env}"
tag="${ADK_IMAGE_TAG:-dev}"
image="$repo/adk-workspace:$tag"
step "Cloud Build adk/app -> $image"
gcloud builds submit "$REPO_ROOT/adk/app" \
  --project "$PROJECT_ID" --region "$REGION" --tag "$image" --timeout 20m --quiet >/dev/null
digest="$(gcloud artifacts docker images describe "$image" --project "$PROJECT_ID" --format='value(image_summary.digest)')"
[[ "$digest" == sha256:* ]] || die "could not read the digest of $image"
ref="${image%%:*}@$digest"
state_put adk-image "$ref"
ok "$ref  (saved to .workshop/adk-image)"
