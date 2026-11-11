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
	"context"
	"fmt"
	"log"
	"net/http"
	"net/http/httputil"
	"net/url"
	"time"

	"github.com/agent-substrate/workshop/app/internal/chatapi"
)

// Lifecycle is the part of ateapi the front door uses when an actor asks to be suspended.
type Lifecycle interface {
	// SuspendSync suspends the actor and returns once its snapshot is in durable storage.
	SuspendSync(ctx context.Context, atespace, name string) error
}

// SuspendSyncTimeout bounds one self-requested suspend. A synchronous suspend includes the
// upload of the snapshot to the bucket, so it is far slower than the async suspend the
// idle-suspender uses.
const SuspendSyncTimeout = 10 * time.Minute

// HandleADK serves /adk/{actor}/{path...}: a streaming reverse proxy to the actor's ADK API
// server (`adk api_server`), the ADK track's counterpart of /chat. The path after the actor
// name is the ADK path (/run_sse, /apps/..., /health). Nothing is buffered: /run_sse answers
// as text/event-stream and every event is flushed to the caller as it arrives. The request
// counts as activity on the actor's idle clock until the last byte of the response is written.
func (f *FrontDoor) HandleADK(w http.ResponseWriter, r *http.Request) {
	actor := r.PathValue("actor")
	if !dnsLabel.MatchString(actor) {
		writeJSON(w, http.StatusBadRequest, chatapi.Error{Error: fmt.Sprintf("invalid actor name %q", actor)})
		return
	}
	target, err := url.Parse(f.RouterURL)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, chatapi.Error{Error: "router url: " + err.Error()})
		return
	}
	outcome := "error"
	defer func() { f.Metrics.ADKRequests.WithLabelValues(outcome).Inc() }()
	done := f.Activity.Begin(actor)
	defer done()
	path := "/" + r.PathValue("path")
	proxy := &httputil.ReverseProxy{
		Rewrite: func(pr *httputil.ProxyRequest) {
			pr.SetURL(target)
			pr.Out.URL.Path, pr.Out.URL.RawPath = path, ""
			pr.Out.Header.Set(RouteHeader, f.Atespace+"/"+actor)
		},
		Transport: f.Client.Transport,
		// Flush every write: SSE events must not wait in a buffer for the stream to end.
		FlushInterval: -1,
		ModifyResponse: func(resp *http.Response) error {
			if resp.StatusCode >= 200 && resp.StatusCode < 300 {
				outcome = "ok"
			}
			return nil
		},
		ErrorHandler: func(w http.ResponseWriter, _ *http.Request, err error) {
			writeJSON(w, http.StatusBadGateway, chatapi.Error{Error: "router: " + err.Error()})
		},
	}
	proxy.ServeHTTP(w, r)
}

// HandleSuspend serves POST /actors/{actor}/suspend: a synchronous SuspendActor on the actor's
// behalf. An actor cannot call the control plane, so this is how the ADK image's PID 1 shim
// turns the SIGTERM of a disappearing worker into SUSPENDED-with-a-durable-snapshot instead
// of CRASHED.
//
// The call is detached from the request on purpose and answered with 202 before it finishes.
// The caller is the process about to be frozen: the checkpoint cuts the sandbox's network
// within milliseconds of SuspendActor starting, the HTTP connection drops, and a handler that
// had tied the RPC to r.Context() would cancel the suspend workflow mid-checkpoint (observed
// as "workflow failed at step CallAteletSuspend: context canceled", then CRASHED). The outcome
// is logged and counted instead; the actor reads it, if ever, from its own resume.
func (f *FrontDoor) HandleSuspend(w http.ResponseWriter, r *http.Request) {
	actor := r.PathValue("actor")
	if !dnsLabel.MatchString(actor) {
		writeJSON(w, http.StatusBadRequest, chatapi.Error{Error: fmt.Sprintf("invalid actor name %q", actor)})
		return
	}
	if f.Lifecycle == nil {
		writeJSON(w, http.StatusNotImplemented, chatapi.Error{Error: "gateway has no ateapi client for suspend"})
		return
	}
	if _, inFlight := f.suspending.LoadOrStore(actor, struct{}{}); inFlight {
		writeJSON(w, http.StatusAccepted, chatapi.SuspendResult{Actor: actor, State: "SUSPENDING"})
		return
	}
	go func() {
		defer f.suspending.Delete(actor)
		ctx, cancel := context.WithTimeout(context.WithoutCancel(r.Context()), SuspendSyncTimeout)
		defer cancel()
		started := time.Now()
		if err := f.Lifecycle.SuspendSync(ctx, f.Atespace, actor); err != nil {
			f.Metrics.SelfSuspends.WithLabelValues("error").Inc()
			log.Printf("self-suspend %s/%s failed after %s: %v", f.Atespace, actor, time.Since(started).Round(time.Millisecond), err)
			return
		}
		f.Metrics.SelfSuspends.WithLabelValues("ok").Inc()
		log.Printf("self-suspend %s/%s: SUSPENDED with a durable snapshot in %s", f.Atespace, actor, time.Since(started).Round(time.Millisecond))
	}()
	writeJSON(w, http.StatusAccepted, chatapi.SuspendResult{Actor: actor, State: "SUSPENDING"})
}
