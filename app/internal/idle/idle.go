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

// Package idle suspends actors nobody is talking to. Substrate keeps a RUNNING actor on its
// worker until someone suspends it, so a platform has to decide what "idle" means. Here:
// no request through the gateway front door for IdleAfter.
package idle

import (
	"context"
	"log"
	"sync"
	"time"

	ateapipb "go.ate.dev/substrate/api/ateapi/v1"
	"github.com/agent-substrate/workshop/app/internal/metrics"
)

// Tracker records the last time each actor finished a request, and which ones are mid-request.
type Tracker struct {
	mu       sync.Mutex
	now      func() time.Time
	last     map[string]time.Time
	inflight map[string]int
}

func NewTracker(now func() time.Time) *Tracker {
	if now == nil {
		now = time.Now
	}
	return &Tracker{now: now, last: map[string]time.Time{}, inflight: map[string]int{}}
}

// Begin marks a request to actor as started. The returned func marks it done and restarts
// the actor's idle clock.
func (t *Tracker) Begin(actor string) func() {
	t.mu.Lock()
	t.inflight[actor]++
	t.last[actor] = t.now()
	t.mu.Unlock()
	var once sync.Once
	return func() {
		once.Do(func() {
			t.mu.Lock()
			t.inflight[actor]--
			t.last[actor] = t.now()
			t.mu.Unlock()
		})
	}
}

// Touch restarts actor's idle clock.
func (t *Tracker) Touch(actor string) {
	t.mu.Lock()
	t.last[actor] = t.now()
	t.mu.Unlock()
}

// idleFor reports how long actor has been idle. An actor seen for the first time (woken by
// something other than the gateway) starts its clock now.
func (t *Tracker) idleFor(actor string) (time.Duration, bool) {
	t.mu.Lock()
	defer t.mu.Unlock()
	if t.inflight[actor] > 0 {
		return 0, true
	}
	last, ok := t.last[actor]
	if !ok {
		t.last[actor] = t.now()
		return 0, false
	}
	return t.now().Sub(last), false
}

// Forget drops an actor so its next wake-up gets a fresh grace period.
func (t *Tracker) Forget(actor string) {
	t.mu.Lock()
	delete(t.last, actor)
	t.mu.Unlock()
}

// ActorInfo is the slice of actor state the suspender needs.
type ActorInfo struct {
	Name    string
	Running bool
}

// API is the part of ateapi the suspender uses.
type API interface {
	ListActors(ctx context.Context, atespace string) ([]ActorInfo, error)
	Suspend(ctx context.Context, atespace, name string) error
}

// GRPC adapts an ateapi Control client to API.
type GRPC struct{ C ateapipb.ControlClient }

func (g GRPC) ListActors(ctx context.Context, atespace string) ([]ActorInfo, error) {
	var out []ActorInfo
	token := ""
	for {
		resp, err := g.C.ListActors(ctx, &ateapipb.ListActorsRequest{
			Atespace: atespace,
			Options:  &ateapipb.ListOptions{PageSize: 100, PageToken: token},
		})
		if err != nil {
			return nil, err
		}
		for _, a := range resp.GetActors() {
			out = append(out, ActorInfo{
				Name:    a.GetMetadata().GetName(),
				Running: a.GetStatus().GetState() == ateapipb.ActorState_ACTOR_STATE_RUNNING,
			})
		}
		if token = resp.GetNextPageToken(); token == "" {
			return out, nil
		}
	}
}

func (g GRPC) Suspend(ctx context.Context, atespace, name string) error {
	_, err := g.C.SuspendActor(ctx, &ateapipb.SuspendActorRequest{Actor: &ateapipb.ObjectRef{Atespace: atespace, Name: name}})
	return err
}

// SuspendSync is Suspend with DURABILITY_MODE_SYNCHRONOUS: it returns once the snapshot is
// in the bucket, not just captured on the node. That is the mode an evicted actor needs,
// because its node may be gone before an asynchronous upload finishes (api-guide "Eviction").
func (g GRPC) SuspendSync(ctx context.Context, atespace, name string) error {
	_, err := g.C.SuspendActor(ctx, &ateapipb.SuspendActorRequest{
		Actor:   &ateapipb.ObjectRef{Atespace: atespace, Name: name},
		Options: &ateapipb.SuspendOptions{Mode: ateapipb.DurabilityMode_DURABILITY_MODE_SYNCHRONOUS},
	})
	return err
}

// DefaultSuspendTimeout bounds one SuspendActor call, so a hung call can't stall every later suspend.
const DefaultSuspendTimeout = 60 * time.Second

// Suspender suspends RUNNING actors idle for at least IdleAfter. IdleAfter <= 0 disables
// suspending but still updates the fleet gauges. SuspendTimeout (default DefaultSuspendTimeout)
// bounds each Suspend call.
type Suspender struct {
	API            API
	Atespace       string
	IdleAfter      time.Duration
	SuspendTimeout time.Duration
	Tracker        *Tracker
	Metrics        *metrics.Metrics
}

// suspend makes one Suspend call under its own timeout.
func (s *Suspender) suspend(ctx context.Context, name string) error {
	timeout := s.SuspendTimeout
	if timeout <= 0 {
		timeout = DefaultSuspendTimeout
	}
	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	return s.API.Suspend(ctx, s.Atespace, name)
}

// Tick runs one check.
func (s *Suspender) Tick(ctx context.Context) error {
	actors, err := s.API.ListActors(ctx, s.Atespace)
	if err != nil {
		return err
	}
	awake := 0
	for _, a := range actors {
		if !a.Running {
			s.Tracker.Forget(a.Name)
			continue
		}
		awake++
		if s.IdleAfter <= 0 {
			continue
		}
		// Checked per actor, right before its Suspend, not once for the whole list: earlier
		// Suspend calls in this Tick can take seconds, and a request may arrive meanwhile.
		// A request that lands after this check still races the RPC; it parks in the router,
		// and the actor resumes to serve it.
		idle, busy := s.Tracker.idleFor(a.Name)
		if busy || idle < s.IdleAfter {
			continue
		}
		if err := s.suspend(ctx, a.Name); err != nil {
			s.Metrics.IdleSuspends.WithLabelValues("error").Inc()
			log.Printf("idle-suspend %s/%s: %v", s.Atespace, a.Name, err)
			continue
		}
		s.Metrics.IdleSuspends.WithLabelValues("ok").Inc()
		s.Tracker.Forget(a.Name)
		awake--
		log.Printf("idle-suspend %s/%s after %s idle", s.Atespace, a.Name, idle.Round(time.Second))
	}
	s.Metrics.ActorsTracked.Set(float64(len(actors)))
	s.Metrics.ActorsAwake.Set(float64(awake))
	return nil
}

// Run calls Tick every interval until ctx is done.
func (s *Suspender) Run(ctx context.Context, every time.Duration) {
	t := time.NewTicker(every)
	defer t.Stop()
	for {
		if err := s.Tick(ctx); err != nil {
			log.Printf("idle check: %v", err)
		}
		select {
		case <-ctx.Done():
			return
		case <-t.C:
		}
	}
}
