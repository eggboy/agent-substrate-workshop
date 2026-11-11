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

# Agent Substrate workshop. Run `make help` for targets.
SHELL := /usr/bin/env bash
.DEFAULT_GOAL := help
MODULE ?=
RESET ?=

help: ## Show targets
	@grep -E '^[a-zA-Z0-9_-]+:.*?## ' $(MAKEFILE_LIST) | awk -F':.*?## ' '{printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'
	@echo
	@echo "  Knobs in [brackets] go after the target: make load DURATION=600 CONCURRENCY=4"
	@echo "  Everything else is set in workshop.env (WORKSHOP_ENV_FILE=path picks another file)."

preflight: ## Check tools and cluster prerequisites
	@scripts/preflight.sh
gcp: ## Create bucket, Artifact Registry repo, IAM bindings
	@scripts/gcp-resources.sh
install: ## Install Agent Substrate (foreground)
	@scripts/install-substrate.sh
install-bg: ## Install Agent Substrate in the background (log: .workshop/install.log)
	@scripts/install-bg.sh
install-status: ## Show background install progress: running, finished, or died
	@scripts/install-bg.sh --status
dashboards: ## Create/update Cloud Monitoring dashboards
	@scripts/dashboards.sh
build-agent: ## ko build the agent -> .workshop/agent-image
	@scripts/build.sh agent --check-changed
build-gateway: ## ko build the gateway -> .workshop/gateway-image
	@scripts/build.sh gateway
build: build-agent build-gateway ## Build the agent and gateway images
adk-image: ## Cloud Build the ADK actor image (adk/app) -> .workshop/adk-image [ADK_IMAGE_TAG=dev]
	@adk/scripts/build-image.sh
gateway: ## Build and deploy the gateway [IDLE_AFTER=3s (default: keep live value) MOCK_LLM=true|false]
	@scripts/build.sh gateway && scripts/gateway.sh
egress: ## Apply an EgressPolicy [POLICY=file, then ACTOR=name or ALL=1]
	@scripts/egress.sh apply "$(POLICY)" "$(if $(ALL),--all,--actor=$(ACTOR))"
tools: ## Build local helper binaries into bin/
	@mkdir -p bin && cd app && go build -o ../bin/egressctl ./cmd/egressctl
load: ## Burst chat traffic across swarm actors [DURATION=180 (s) CONCURRENCY=2 ACTORS="swarm-01 swarm-02 …"]
	@scripts/load.sh
observe: ## Deploy the gateway PodMonitoring and the Prometheus UI
	@scripts/observability.sh
prometheus-ui: ## Port-forward the Prometheus UI to http://localhost:9090
	@source scripts/lib.sh && load_env && port_forward prom-ui $$NAMESPACE svc/prometheus-ui 9090 9090 && open_hint 9090
forward-router: ## (Re)start the atenet-router port-forward on http://localhost:8080
	@source scripts/lib.sh && load_env && stop_port_forward router && port_forward router ate-system svc/atenet-router 8080 80 && echo "open http://localhost:8080"
forward-gateway: ## (Re)start the gateway port-forward on http://localhost:8081
	@source scripts/lib.sh && load_env && stop_port_forward gateway && port_forward gateway $$NAMESPACE svc/gateway 8081 80 && echo "open http://localhost:8081"
patch-router: ## Re-apply the workshop router settings (60s park budget, 120s grace) after a substrate reinstall
	@scripts/patch-router.sh
idle-off: ## Turn the gateway's idle-suspend off (IDLE_AFTER=0s) and restart the gateway port-forward
	@scripts/idle.sh off
idle-on: ## Turn idle-suspend back on and restart the gateway port-forward [IDLE_AFTER=3s]
	@scripts/idle.sh on
catch-up: ## Bring your environment to the start of a module [MODULE=N RESET=1 (rebuild its template)]
	@RESET="$(RESET)" scripts/catch-up.sh "$(MODULE)"
verify: ## Check the end state of a module [MODULE=N]
	@scripts/verify/$$(printf '%02d' "$(MODULE)").sh
e2e: ## Run every module via catch-up + verify
	@for n in 1 2 3 4 5 6 7; do scripts/catch-up.sh $$n && scripts/verify/$$(printf '%02d' $$((n-1))).sh || exit 1; done
test: test-go test-scripts ## Run all offline tests
test-go: ## Run go vet and the Go tests
	@cd app && go vet ./... && go test ./...
test-scripts: ## Run the shell script tests
	@bash scripts/test/lib_test.sh && bash scripts/test/render_test.sh && bash scripts/test/dashboards_test.sh && bash scripts/test/solutions_test.sh && bash scripts/test/preflight_test.sh && bash scripts/test/delete_cluster_test.sh
stop-forwards: ## Stop background port-forwards
	@source scripts/lib.sh && stop_port_forwards
teardown: ## Delete workshop resources, keeps the cluster [ALL=1 (also bucket, repo, IAM) YES=1 (no prompt)]
	@scripts/teardown.sh $(if $(ALL),--all)
delete-cluster: ## Delete the GKE cluster, its PVCs and their disks first; run teardown before [YES=1 (no prompt)]
	@scripts/delete-cluster.sh
clean: ## Remove local build output (bin/, dist/)
	@rm -rf bin dist
.PHONY: help preflight gcp install install-bg install-status dashboards build-agent build-gateway build gateway egress tools load observe prometheus-ui forward-router forward-gateway patch-router idle-off idle-on catch-up verify e2e test test-go test-scripts stop-forwards teardown delete-cluster clean
