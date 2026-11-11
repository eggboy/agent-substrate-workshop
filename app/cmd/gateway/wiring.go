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

package main

import (
	"context"
	"fmt"
	"net/http"
	"os"
	"strings"

	"cloud.google.com/go/auth/credentials"
	"github.com/agent-substrate/workshop/app/internal/ateclient"
	"github.com/agent-substrate/workshop/app/internal/frontdoor"
	"github.com/agent-substrate/workshop/app/internal/idle"
	"github.com/agent-substrate/workshop/app/internal/metrics"
	"github.com/agent-substrate/workshop/app/internal/vertexproxy"
	ateapipb "go.ate.dev/substrate/api/ateapi/v1"
)

func routerHTTPClient(cfg config) (*http.Client, error) {
	if !strings.HasPrefix(cfg.RouterURL, "https://") {
		return &http.Client{}, nil
	}
	tc, err := ateclient.TLSConfig(ateclient.Options{
		ServerName:     cfg.RouterServerName,
		CAFile:         cfg.ATE.CAFile,
		ClientCertFile: cfg.RouterClientCert,
		Insecure:       cfg.ATE.Insecure,
	})
	if err != nil {
		return nil, err
	}
	tr := http.DefaultTransport.(*http.Transport).Clone()
	tr.TLSClientConfig = tc
	tr.ForceAttemptHTTP2 = true
	return &http.Client{Transport: tr}, nil
}

// buildComponents wires the front door and the idle-suspender around one shared
// *idle.Tracker: every chat the front door proxies restarts the same idle clock the
// suspender reads to decide when to suspend an actor. Returning both from one constructor
// keeps that invariant something a test can check, instead of something two separate call
// sites in main must independently get right.
func buildComponents(cfg config, ate ateapipb.ControlClient, m *metrics.Metrics) (*frontdoor.FrontDoor, *idle.Suspender, error) {
	hc, err := routerHTTPClient(cfg)
	if err != nil {
		return nil, nil, err
	}
	tracker := idle.NewTracker(nil)
	fd := &frontdoor.FrontDoor{
		RouterURL: cfg.RouterURL,
		Atespace:  cfg.Atespace,
		SelfURL:   cfg.SelfURL,
		// No fixed timeout: atenet-router already bounds each call with its own
		// parked-request budget (60s) and route-timeout (5m default). A shorter client
		// timeout here would cut off a legitimate resume-and-answer turn that the router
		// itself would have completed.
		Client:   hc,
		Activity: tracker,
		Metrics:  m,
		// The same ateapi client the idle-suspender uses, for the sync suspend an actor's
		// SIGTERM handler asks for (ADK track).
		Lifecycle: idle.GRPC{C: ate},
	}
	suspender := &idle.Suspender{API: idle.GRPC{C: ate}, Atespace: cfg.Atespace, IdleAfter: cfg.IdleAfter, Tracker: tracker, Metrics: m}
	return fd, suspender, nil
}

// newVertexProxy builds the approach-B proxy on the gateway's own Google credentials
// (Workload Identity in the cluster, ADC elsewhere). GOOGLE_CLOUD_LOCATION picks the Vertex
// endpoint, the same variable the gateway's own model client reads.
func newVertexProxy(ctx context.Context, cfg config) (*vertexproxy.Proxy, error) {
	creds, err := credentials.DetectDefault(&credentials.DetectOptions{
		Scopes: []string{"https://www.googleapis.com/auth/cloud-platform"},
	})
	if err != nil {
		return nil, err
	}
	if _, err := creds.Token(ctx); err != nil {
		return nil, fmt.Errorf("no usable Google credentials: %w", err)
	}
	location := os.Getenv("GOOGLE_CLOUD_LOCATION")
	if location == "" {
		location = "global"
	}
	return &vertexproxy.Proxy{
		Project:  cfg.Project,
		Location: location,
		Tokens: vertexproxy.TokenFunc(func(ctx context.Context) (string, error) {
			tok, err := creds.Token(ctx)
			if err != nil {
				return "", err
			}
			return tok.Value, nil
		}),
	}, nil
}
