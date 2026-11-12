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

// Package metrics holds the gateway's Prometheus metrics. Substrate exports its own metrics
// through OpenTelemetry; these are the application-side view of the same fleet.
package metrics

import (
	"net/http"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/collectors"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

type Metrics struct {
	Registry      *prometheus.Registry
	ChatTurns     *prometheus.CounterVec
	ModelDuration *prometheus.HistogramVec
	ModelTokens   *prometheus.CounterVec
	IdleSuspends  *prometheus.CounterVec
	SelfSuspends  *prometheus.CounterVec
	ADKRequests   *prometheus.CounterVec
	BusyBeats     prometheus.Counter
	ActorsTracked prometheus.Gauge
	ActorsAwake   prometheus.Gauge
}

func New() *Metrics {
	m := &Metrics{
		Registry: prometheus.NewRegistry(),
		ChatTurns: prometheus.NewCounterVec(prometheus.CounterOpts{
			Name: "workshop_chat_turns_total",
			Help: "Chat turns sent through the gateway front door, by outcome (ok, error).",
		}, []string{"outcome"}),
		ModelDuration: prometheus.NewHistogramVec(prometheus.HistogramOpts{
			Name:    "workshop_model_request_duration_seconds",
			Help:    "Latency of /v1/model calls, by backend and outcome.",
			Buckets: []float64{.05, .1, .25, .5, 1, 2, 4, 8, 16, 32},
		}, []string{"backend", "outcome"}),
		ModelTokens: prometheus.NewCounterVec(prometheus.CounterOpts{
			Name: "workshop_model_tokens_total",
			Help: "Model tokens, by backend and direction (input, output).",
		}, []string{"backend", "direction"}),
		IdleSuspends: prometheus.NewCounterVec(prometheus.CounterOpts{
			Name: "workshop_idle_suspends_total",
			Help: "Suspend calls made by the idle-suspender, by outcome (ok, error).",
		}, []string{"outcome"}),
		SelfSuspends: prometheus.NewCounterVec(prometheus.CounterOpts{
			Name: "workshop_self_suspends_total",
			Help: "Synchronous suspends requested through /actors/{actor}/suspend (an actor's SIGTERM path), by outcome (ok, error).",
		}, []string{"outcome"}),
		ADKRequests: prometheus.NewCounterVec(prometheus.CounterOpts{
			Name: "workshop_adk_requests_total",
			Help: "Requests proxied to ADK actors through /adk/{actor}/, by outcome (ok: the actor answered, any status below 500; error: router or actor failure).",
		}, []string{"outcome"}),
		BusyBeats: prometheus.NewCounter(prometheus.CounterOpts{
			Name: "workshop_busy_heartbeats_total",
			Help: "Busy heartbeats from actors' background jobs, each restarting that actor's idle clock.",
		}),
		ActorsTracked: prometheus.NewGauge(prometheus.GaugeOpts{
			Name: "workshop_actors_tracked",
			Help: "Actors in the workshop atespace at the last idle check.",
		}),
		ActorsAwake: prometheus.NewGauge(prometheus.GaugeOpts{
			Name: "workshop_actors_awake",
			Help: "Actors in RUNNING state at the last idle check.",
		}),
	}
	m.Registry.MustRegister(
		m.ChatTurns, m.ModelDuration, m.ModelTokens, m.IdleSuspends, m.SelfSuspends, m.ADKRequests, m.BusyBeats, m.ActorsTracked, m.ActorsAwake,
		collectors.NewGoCollector(),
		collectors.NewProcessCollector(collectors.ProcessCollectorOpts{}),
	)
	return m
}

// ObserveModel records one /v1/model call.
func (m *Metrics) ObserveModel(backend, outcome string, d time.Duration, in, out int) {
	m.ModelDuration.WithLabelValues(backend, outcome).Observe(d.Seconds())
	m.ModelTokens.WithLabelValues(backend, "input").Add(float64(in))
	m.ModelTokens.WithLabelValues(backend, "output").Add(float64(out))
}

// Handler serves /metrics.
func (m *Metrics) Handler() http.Handler {
	return promhttp.HandlerFor(m.Registry, promhttp.HandlerOpts{Registry: m.Registry})
}
