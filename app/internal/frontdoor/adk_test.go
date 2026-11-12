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
	mu      sync.Mutex
	calls   []string
	err     error
	started chan struct{} // closed when SuspendSync is entered
	release chan struct{} // SuspendSync blocks until this is closed, when non-nil
	ctxErr  error         // the ctx error observed when release opened
}

func (l *fakeLifecycle) SuspendSync(ctx context.Context, atespace, name string) error {
	l.mu.Lock()
	l.calls = append(l.calls, atespace+"/"+name)
	l.mu.Unlock()
	if l.started != nil {
		close(l.started)
	}
	if l.release != nil {
		<-l.release
		l.mu.Lock()
		l.ctxErr = ctx.Err()
		l.mu.Unlock()
	}
	return l.err
}

func (l *fakeLifecycle) snapshot() ([]string, error) {
	l.mu.Lock()
	defer l.mu.Unlock()
	return append([]string(nil), l.calls...), l.ctxErr
}

func waitFor(t *testing.T, what string, cond func() bool) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for !cond() {
		if time.Now().After(deadline) {
			t.Fatalf("timed out waiting for %s", what)
		}
		time.Sleep(10 * time.Millisecond)
	}
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

func TestADKCountsClientErrorsAsAnswered(t *testing.T) {
	gw, _, m := setupADK(t, func(w http.ResponseWriter, r *http.Request) {
		http.Error(w, `{"detail":"Session already exists: s1"}`, http.StatusConflict)
	}, nil)
	resp, err := http.Post(gw.URL+"/adk/buddy/apps/workspace/users/u1/sessions/s1", "application/json", strings.NewReader(`{}`))
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusConflict {
		t.Fatalf("upstream status not propagated: %d", resp.StatusCode)
	}
	if promtest.ToFloat64(m.ADKRequests.WithLabelValues("ok")) != 1 || promtest.ToFloat64(m.ADKRequests.WithLabelValues("error")) != 0 {
		t.Fatal("a 4xx from the ADK server is an answered request, not a proxy error")
	}
}

func TestSuspendIsAcceptedAndRunsSynchronousSuspend(t *testing.T) {
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
	if resp.StatusCode != http.StatusAccepted || out.Actor != "buddy" || out.State != "SUSPENDING" {
		t.Fatalf("gateway = %d %+v", resp.StatusCode, out)
	}
	waitFor(t, "the ok counter", func() bool { return promtest.ToFloat64(m.SelfSuspends.WithLabelValues("ok")) == 1 })
	if calls, _ := lc.snapshot(); len(calls) != 1 || calls[0] != "workshop/buddy" {
		t.Fatalf("ateapi calls = %v", calls)
	}
}

// The caller of /suspend is the actor about to be frozen: its connection drops as soon as the
// checkpoint starts. The suspend must not die with it (that is exactly what left an actor
// CRASHED in the first drill: "CallAteletSuspend: context canceled").
func TestSuspendOutlivesTheCallerConnection(t *testing.T) {
	lc := &fakeLifecycle{started: make(chan struct{}), release: make(chan struct{})}
	gw, _, m := setupADK(t, nil, lc)
	ctx, cancel := context.WithCancel(context.Background())
	req, _ := http.NewRequestWithContext(ctx, http.MethodPost, gw.URL+"/actors/buddy/suspend", nil)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusAccepted {
		t.Fatalf("gateway = %d", resp.StatusCode)
	}
	<-lc.started
	cancel() // the actor's connection is gone; the suspend must carry on
	time.Sleep(50 * time.Millisecond)
	close(lc.release)
	waitFor(t, "the ok counter", func() bool { return promtest.ToFloat64(m.SelfSuspends.WithLabelValues("ok")) == 1 })
	if _, ctxErr := lc.snapshot(); ctxErr != nil {
		t.Fatalf("suspend context was cancelled with the caller: %v", ctxErr)
	}
}

func TestSuspendDeduplicatesWhileInFlight(t *testing.T) {
	lc := &fakeLifecycle{started: make(chan struct{}), release: make(chan struct{})}
	gw, _, _ := setupADK(t, nil, lc)
	for i := 0; i < 3; i++ {
		resp, err := http.Post(gw.URL+"/actors/buddy/suspend", "", nil)
		if err != nil {
			t.Fatal(err)
		}
		resp.Body.Close()
		if resp.StatusCode != http.StatusAccepted {
			t.Fatalf("call %d = %d", i, resp.StatusCode)
		}
	}
	<-lc.started
	close(lc.release)
	waitFor(t, "the single call", func() bool { calls, _ := lc.snapshot(); return len(calls) == 1 })
	time.Sleep(50 * time.Millisecond)
	if calls, _ := lc.snapshot(); len(calls) != 1 {
		t.Fatalf("retries while in flight started extra suspends: %v", calls)
	}
}

func TestSuspendCountsAteapiErrors(t *testing.T) {
	lc := &fakeLifecycle{err: errors.New("actor not RUNNING")}
	gw, _, m := setupADK(t, nil, lc)
	resp, err := http.Post(gw.URL+"/actors/buddy/suspend", "", nil)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusAccepted {
		t.Fatalf("gateway = %d", resp.StatusCode)
	}
	waitFor(t, "the error counter", func() bool { return promtest.ToFloat64(m.SelfSuspends.WithLabelValues("error")) == 1 })
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
