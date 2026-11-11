// Copyright 2026 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

// Command gateway is the workshop's always-on Deployment next to the actors. It holds what
// must not live in an actor: model credentials (Workload Identity → the Gemini platform), the public
// chat entry point, and the policy deciding when an actor is idle.
package main

import (
	"context"
	"io"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/agent-substrate/workshop/app/internal/ateclient"
	"github.com/agent-substrate/workshop/app/internal/metrics"
	"github.com/agent-substrate/workshop/app/internal/model"
)

func main() {
	cfg, err := loadConfig(os.Getenv)
	if err != nil {
		log.Fatalf("gateway config: %v", err)
	}
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	m := metrics.New()
	backend := model.Select(cfg.MockLLM, func() (model.Backend, error) {
		return model.NewGemini(ctx, cfg.Project, cfg.GeminiModel)
	})

	ate, closer, err := ateclient.Dial(cfg.ATE)
	if err != nil {
		log.Fatalf("ateapi: %v", err)
	}
	defer closer.Close()

	fd, suspender, err := buildComponents(cfg, ate, m)
	if err != nil {
		log.Fatalf("router client: %v", err)
	}
	go suspender.Run(ctx, cfg.IdleCheckEvery)

	mux := http.NewServeMux()
	mux.Handle("POST /v1/model", model.Handler(backend, m))
	mux.HandleFunc("POST /chat/{actor}", fd.HandleChat)
	mux.HandleFunc("GET /actors/{actor}/state", fd.HandleState)
	mux.HandleFunc("GET /actors/{actor}/work", fd.HandleWork)
	mux.HandleFunc("POST /actors/{actor}/jobs", fd.HandleJob)
	mux.HandleFunc("POST /actors/{actor}/busy", fd.HandleBusy)
	// ADK track: stream the ADK API server of an actor, and let an actor ask for its own
	// synchronous suspend (its SIGTERM path).
	mux.HandleFunc("/adk/{actor}/{path...}", fd.HandleADK)
	mux.HandleFunc("POST /actors/{actor}/suspend", fd.HandleSuspend)
	// ADK track, approach B: Developer-API-shaped calls from actors, served on Vertex AI with
	// the gateway's Workload Identity. Only when the gateway knows its project.
	if cfg.Project != "" {
		vp, err := newVertexProxy(ctx, cfg)
		if err != nil {
			log.Printf("vertex proxy disabled: %v", err)
		} else {
			mux.Handle("/genai/{path...}", vp)
		}
	}
	mux.Handle("GET /metrics", m.Handler())
	mux.HandleFunc("GET /readyz", func(w http.ResponseWriter, _ *http.Request) {
		if ctx.Err() != nil {
			http.Error(w, "draining\n", http.StatusServiceUnavailable)
			return
		}
		_, _ = io.WriteString(w, "ok\n")
	})

	srv := &http.Server{Addr: cfg.ListenAddr, Handler: mux, ReadHeaderTimeout: 10 * time.Second}
	go func() {
		<-ctx.Done()
		// Disable keep-alives immediately so any /v1/model response served during the drain
		// window sends Connection: close, preventing atenet-egress Envoy from pooling a
		// connection to a terminating gateway pod and failing the next turn with 503 UC.
		srv.SetKeepAlivesEnabled(false)
		// Keep the listener open briefly after SIGTERM so /v1/model calls routed via a cached Service
		// endpoint during a gateway rollout don't fail before EndpointSlice removal propagates.
		time.Sleep(3 * time.Second)
		shutdown, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		_ = srv.Shutdown(shutdown)
	}()
	log.Printf("gateway on %s: atespace=%s model=%s idleAfter=%s", cfg.ListenAddr, cfg.Atespace, backend.Name(), cfg.IdleAfter)
	if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
		log.Fatal(err)
	}
}
