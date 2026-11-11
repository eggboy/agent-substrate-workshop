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

// Package chatapi holds the JSON shapes shared by the agent, the gateway, and the load tool.
package chatapi

// BusyURLHeader carries the URL an actor's background job reports "still busy" to. The gateway
// sets it, because an actor can't know its own name: every clone has the hostname "actor" and
// the same memory at boot.
const BusyURLHeader = "Busy-URL"

// Message is one turn in a conversation. Role is "user" or "assistant".
type Message struct {
	Role    string `json:"role"`
	Content string `json:"content"`
}

// ChatRequest is what a caller POSTs to an actor's /chat.
type ChatRequest struct {
	Message string `json:"message"`
}

// ChatResponse is what an actor's /chat returns.
type ChatResponse struct {
	Reply   string `json:"reply"`
	Turn    int    `json:"turn"`
	Backend string `json:"backend"`
}

// ModelRequest is what an actor POSTs to the gateway's /v1/model.
type ModelRequest struct {
	Messages []Message `json:"messages"`
}

// ModelResponse is what the gateway's /v1/model returns.
type ModelResponse struct {
	Reply        string `json:"reply"`
	Backend      string `json:"backend"`
	InputTokens  int    `json:"inputTokens"`
	OutputTokens int    `json:"outputTokens"`
	// UpstreamError says why Gemini didn't answer, when Backend is "mock-fallback".
	UpstreamError string `json:"upstreamError,omitempty"`
}

// Error is the body of every non-2xx JSON response.
type Error struct {
	Error string `json:"error"`
}

// SuspendResult is the body of a successful POST /actors/{actor}/suspend: the actor is
// SUSPENDED with a durable snapshot, and Seconds is how long the synchronous suspend took.
type SuspendResult struct {
	Actor   string  `json:"actor"`
	State   string  `json:"state"`
	Seconds float64 `json:"seconds"`
}
