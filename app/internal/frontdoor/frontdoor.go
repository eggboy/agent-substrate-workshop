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

// Package frontdoor is the gateway's public chat API. It turns /chat/{actor} into a request
// to atenet-router carrying the ate-target-actor header. The router resumes the actor if it
// is suspended and parks the request until it is ready. Each call is also recorded as
// activity, so the idle-suspender knows which actors are in use.
package frontdoor

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"regexp"
	"strings"

	"github.com/agent-substrate/workshop/app/internal/chatapi"
	"github.com/agent-substrate/workshop/app/internal/metrics"
)

// RouteHeader tells atenet-router which actor a request is for, as "<atespace>/<actor>".
const RouteHeader = "ate-target-actor"

var dnsLabel = regexp.MustCompile(`^[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?$`)

// Activity is told when a request to an actor starts; the returned func marks it finished.
// Touch counts as activity without a request, for a background job's heartbeat.
type Activity interface {
	Begin(actor string) (done func())
	Touch(actor string)
}

type FrontDoor struct {
	RouterURL string
	Atespace  string
	// SelfURL is the gateway's address as actors reach it (in-cluster), used to build the
	// Busy-URL for background jobs. Empty: jobs get no Busy-URL.
	SelfURL  string
	Client   *http.Client
	Activity Activity
	Metrics  *metrics.Metrics
	// Lifecycle suspends an actor on its own request (POST /actors/{actor}/suspend). Nil
	// turns that endpoint off with a 501.
	Lifecycle Lifecycle
}

// HandleChat serves POST /chat/{actor}.
func (f *FrontDoor) HandleChat(w http.ResponseWriter, r *http.Request) {
	outcome := "error"
	defer func() { f.Metrics.ChatTurns.WithLabelValues(outcome).Inc() }()
	actor := r.PathValue("actor")
	if !dnsLabel.MatchString(actor) {
		writeJSON(w, http.StatusBadRequest, chatapi.Error{Error: fmt.Sprintf("invalid actor name %q", actor)})
		return
	}
	body, err := io.ReadAll(io.LimitReader(r.Body, 1<<20))
	if err != nil {
		writeJSON(w, http.StatusBadRequest, chatapi.Error{Error: err.Error()})
		return
	}
	if f.forward(w, r.Context(), http.MethodPost, actor, "/chat", body) {
		outcome = "ok"
	}
}

// HandleState serves GET /actors/{actor}/state.
func (f *FrontDoor) HandleState(w http.ResponseWriter, r *http.Request) {
	actor := r.PathValue("actor")
	if !dnsLabel.MatchString(actor) {
		writeJSON(w, http.StatusBadRequest, chatapi.Error{Error: fmt.Sprintf("invalid actor name %q", actor)})
		return
	}
	f.forward(w, r.Context(), http.MethodGet, actor, "/state", nil)
}

// HandleWork serves GET /actors/{actor}/work?steps=N: a slow request the idle tracker can see.
func (f *FrontDoor) HandleWork(w http.ResponseWriter, r *http.Request) {
	actor := r.PathValue("actor")
	if !dnsLabel.MatchString(actor) {
		writeJSON(w, http.StatusBadRequest, chatapi.Error{Error: fmt.Sprintf("invalid actor name %q", actor)})
		return
	}
	f.forward(w, r.Context(), http.MethodGet, actor, "/work?steps="+url.QueryEscape(r.URL.Query().Get("steps")), nil)
}

// HandleJob serves POST /actors/{actor}/jobs?steps=N: a background job. The actor answers 202
// right away, so no request stays in flight. Busy-URL tells it where to report that it's still
// busy; an actor can't know its own name, so the gateway hands it one (optional lab C).
func (f *FrontDoor) HandleJob(w http.ResponseWriter, r *http.Request) {
	actor := r.PathValue("actor")
	if !dnsLabel.MatchString(actor) {
		writeJSON(w, http.StatusBadRequest, chatapi.Error{Error: fmt.Sprintf("invalid actor name %q", actor)})
		return
	}
	var hdr http.Header
	if f.SelfURL != "" {
		hdr = http.Header{chatapi.BusyURLHeader: {strings.TrimSuffix(f.SelfURL, "/") + "/actors/" + actor + "/busy"}}
	}
	f.forward(w, r.Context(), http.MethodPost, actor, "/jobs?steps="+url.QueryEscape(r.URL.Query().Get("steps")), nil, hdr)
}

// HandleBusy serves POST /actors/{actor}/busy: a heartbeat from a background job. It restarts
// the actor's idle clock, the same as a finished request would.
func (f *FrontDoor) HandleBusy(w http.ResponseWriter, r *http.Request) {
	actor := r.PathValue("actor")
	if !dnsLabel.MatchString(actor) {
		writeJSON(w, http.StatusBadRequest, chatapi.Error{Error: fmt.Sprintf("invalid actor name %q", actor)})
		return
	}
	f.Activity.Touch(actor)
	f.Metrics.BusyBeats.Inc()
	w.WriteHeader(http.StatusNoContent)
}

// forward proxies one request to the actor through the router and reports whether it got a 2xx.
// hdr adds request headers on top of the routing header.
func (f *FrontDoor) forward(w http.ResponseWriter, ctx context.Context, method, actor, path string, body []byte, hdr ...http.Header) bool {
	done := f.Activity.Begin(actor)
	defer done()
	req, err := http.NewRequestWithContext(ctx, method, strings.TrimSuffix(f.RouterURL, "/")+path, bytes.NewReader(body))
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, chatapi.Error{Error: err.Error()})
		return false
	}
	for _, h := range hdr {
		for k, vs := range h {
			for _, v := range vs {
				req.Header.Add(k, v)
			}
		}
	}
	req.Header.Set(RouteHeader, f.Atespace+"/"+actor)
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	resp, err := f.Client.Do(req)
	if err != nil {
		writeJSON(w, http.StatusBadGateway, chatapi.Error{Error: "router: " + err.Error()})
		return false
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(io.LimitReader(resp.Body, 4<<20))
	ok := resp.StatusCode >= 200 && resp.StatusCode < 300
	if !ok && !json.Valid(b) {
		// The router answers errors in plain text; keep the status, make the body JSON.
		writeJSON(w, resp.StatusCode, chatapi.Error{Error: fmt.Sprintf("router: %s: %s", resp.Status, strings.TrimSpace(string(b)))})
		return false
	}
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(resp.StatusCode)
	_, _ = w.Write(b)
	return ok
}

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(v)
}
