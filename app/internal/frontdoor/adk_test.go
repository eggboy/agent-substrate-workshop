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

package frontdoor

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/agent-substrate/workshop/app/internal/chatapi"
	"github.com/agent-substrate/workshop/app/internal/metrics"
	promtest "github.com/prometheus/client_golang/prometheus/testutil"
)

type fakeLifecycle struct {
	mu    sync.Mutex
	calls []string
	err   error
}

func (l *fakeLifecycle) SuspendSync(_ context.Context, atespace, name string) error {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.calls = append(l.calls, atespace+"/"+name)
	return l.err
}

func setupADK(t *testing.T, router http.HandlerFunc, lc Lifecycle) (*httptest.Server, *recorder, *metrics.Metrics) {
	t.Helper()
	up := httptest.NewServer(router)
	t.Cleanup(up.Close)
	rec, m := &recorder{}, metrics.New()
	fd := &FrontDoor{RouterURL: up.URL, Atespace: "workshop", Client: up.Client(), Activity: rec, Metrics: m, Lifecycle: lc}
	mux := http.NewServeMux()
	mux.HandleFunc("/adk/{actor}/{path...}", fd.HandleADK)
	mux.HandleFunc("POST /actors/{actor}/suspend", fd.HandleSuspend)
	gw := httptest.NewServer(mux)
	t.Cleanup(gw.Close)
	return gw, rec, m
}

func TestADKStreamsEventsBeforeTheResponseEnds(t *testing.T) {
	var gotHeader, gotPath, gotQuery, gotBody string
	release := make(chan struct{})
	gw, rec, m := setupADK(t, func(w http.ResponseWriter, r *http.Request) {
		gotHeader, gotPath, gotQuery = r.Header.Get(RouteHeader), r.URL.Path, r.URL.RawQuery
		b, _ := io.ReadAll(r.Body)
		gotBody = string(b)
		w.Header().Set("Content-Type", "text/event-stream")
		w.WriteHeader(http.StatusOK)
		_, _ = io.WriteString(w, "data: {\"n\":1}\n\n")
		w.(http.Flusher).Flush()
		<-release // the second event only goes out once the test has read the first
		_, _ = io.WriteString(w, "data: {\"n\":2}\n\n")
	}, nil)
	resp, err := http.Post(gw.URL+"/adk/buddy/run_sse?streaming=true", "application/json", strings.NewReader(`{"appName":"workspace"}`))
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 || !strings.HasPrefix(resp.Header.Get("Content-Type"), "text/event-stream") {
		t.Fatalf("gateway = %d %s", resp.StatusCode, resp.Header.Get("Content-Type"))
	}
	br := bufio.NewReader(resp.Body)
	first := make(chan string, 1)
	go func() { line, _ := br.ReadString('\n'); first <- line }()
	select {
	case line := <-first:
		if line != "data: {\"n\":1}\n" {
			t.Fatalf("first event = %q", line)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("first SSE event was buffered until the stream ended")
	}
	close(release)
	rest, _ := io.ReadAll(br)
	if !strings.Contains(string(rest), `{"n":2}`) {
		t.Fatalf("rest = %q", rest)
	}
	if gotHeader != "workshop/buddy" || gotPath != "/run_sse" || gotQuery != "streaming=true" || gotBody != `{"appName":"workspace"}` {
		t.Fatalf("router saw header=%q path=%q query=%q body=%q", gotHeader, gotPath, gotQuery, gotBody)
	}
	rec.mu.Lock()
	defer rec.mu.Unlock()
	if len(rec.begun) != 1 || len(rec.ended) != 1 || rec.begun[0] != "buddy" {
		t.Fatalf("activity begun=%v ended=%v", rec.begun, rec.ended)
	}
	if promtest.ToFloat64(m.ADKRequests.WithLabelValues("ok")) != 1 {
		t.Fatal("ok request not counted")
	}
}

func TestADKRejectsBadActorAndReportsRouterErrors(t *testing.T) {
	gw, rec, m := setupADK(t, func(w http.ResponseWriter, r *http.Request) {
		http.Error(w, "no worker available", http.StatusServiceUnavailable)
	}, nil)
	resp, err := http.Get(gw.URL + "/adk/Not_Valid/health")
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusBadRequest {
		t.Fatalf("bad actor name = %d", resp.StatusCode)
	}
	resp, err = http.Get(gw.URL + "/adk/buddy/health")
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusServiceUnavailable {
		t.Fatalf("upstream status not propagated: %d", resp.StatusCode)
	}
	if len(rec.begun) != 1 || len(rec.ended) != 1 {
		t.Fatalf("activity begun=%v ended=%v", rec.begun, rec.ended)
	}
	if promtest.ToFloat64(m.ADKRequests.WithLabelValues("error")) != 1 {
		t.Fatal("error request not counted")
	}
}

func TestSuspendCallsAteapiSynchronously(t *testing.T) {
	lc := &fakeLifecycle{}
	gw, _, m := setupADK(t, func(w http.ResponseWriter, r *http.Request) { t.Error("router must not be called") }, lc)
	resp, err := http.Post(gw.URL+"/actors/buddy/suspend", "", nil)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	var out chatapi.SuspendResult
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		t.Fatal(err)
	}
	if resp.StatusCode != 200 || out.Actor != "buddy" || out.State != "SUSPENDED" {
		t.Fatalf("gateway = %d %+v", resp.StatusCode, out)
	}
	if len(lc.calls) != 1 || lc.calls[0] != "workshop/buddy" {
		t.Fatalf("ateapi calls = %v", lc.calls)
	}
	if promtest.ToFloat64(m.SelfSuspends.WithLabelValues("ok")) != 1 {
		t.Fatal("ok suspend not counted")
	}
}

func TestSuspendReportsAteapiErrorsAsBadGateway(t *testing.T) {
	lc := &fakeLifecycle{err: errors.New("actor not RUNNING")}
	gw, _, m := setupADK(t, nil, lc)
	resp, err := http.Post(gw.URL+"/actors/buddy/suspend", "", nil)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	var out chatapi.Error
	_ = json.NewDecoder(resp.Body).Decode(&out)
	if resp.StatusCode != http.StatusBadGateway || !strings.Contains(out.Error, "actor not RUNNING") {
		t.Fatalf("gateway = %d %+v", resp.StatusCode, out)
	}
	if promtest.ToFloat64(m.SelfSuspends.WithLabelValues("error")) != 1 {
		t.Fatal("error suspend not counted")
	}
}

func TestSuspendWithoutLifecycleIs501(t *testing.T) {
	gw, _, _ := setupADK(t, nil, nil)
	resp, err := http.Post(gw.URL+"/actors/buddy/suspend", "", nil)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusNotImplemented {
		t.Fatalf("gateway = %d", resp.StatusCode)
	}
}
