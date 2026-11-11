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

// Package vertexproxy is approach B of the ADK track: the actor's google-genai client keeps
// talking the Gemini Developer API (API-key mode, GOOGLE_GEMINI_BASE_URL pointed at the
// gateway), and the gateway turns each call into the same call on Vertex AI, authenticated
// with its own Workload Identity. No key exists anywhere, the sandbox has no route to the
// internet at all, and every request is attributed to an actor: the egress gateway replaces
// the client's x-goog-api-key header with a Substrate-minted actor JWT (an `actorJwt`
// credential header on the http rule), so the header that used to carry a shared secret now
// carries the caller's identity.
package vertexproxy

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"net/http/httputil"
	"net/url"
	"regexp"
	"strings"
	"time"
)

// TokenSource yields a bearer token for Vertex AI (the gateway's Google credentials).
type TokenSource interface {
	Token(ctx context.Context) (string, error)
}

// TokenFunc adapts a function to TokenSource.
type TokenFunc func(ctx context.Context) (string, error)

func (f TokenFunc) Token(ctx context.Context) (string, error) { return f(ctx) }

// Proxy serves /genai/{path...}.
type Proxy struct {
	Project  string
	Location string // "global" or a region such as us-central1
	Tokens   TokenSource
	// Upstream overrides the Vertex AI base URL (tests). Empty: derived from Location.
	Upstream  string
	Transport http.RoundTripper
}

// Gemini Developer API shape: v1beta/models/{model}:{method}. Only model methods are
// translated; anything else (file uploads, caches, tuning) is not available on this path.
var modelPath = regexp.MustCompile(`^/v1(?:beta|alpha)?/models/([^/:]+):([A-Za-z]+)$`)

// Translate maps a Developer API path to its Vertex AI equivalent.
func Translate(project, location, path string) (string, error) {
	m := modelPath.FindStringSubmatch(path)
	if m == nil {
		return "", fmt.Errorf("not a Gemini model call: %s", path)
	}
	return fmt.Sprintf("/v1/projects/%s/locations/%s/publishers/google/models/%s:%s", project, location, m[1], m[2]), nil
}

// BaseURL is the Vertex AI endpoint for a location.
func BaseURL(location string) string {
	if location == "" || location == "global" {
		return "https://aiplatform.googleapis.com"
	}
	return "https://" + location + "-aiplatform.googleapis.com"
}

// Subject returns the `sub` claim of an unverified JWT, or "" when the value is not a JWT.
// The gateway only logs it; a production gateway verifies the token against the issuer's
// OpenID discovery document (ate-idp-server) before trusting it for authorization.
func Subject(token string) string {
	parts := strings.Split(token, ".")
	if len(parts) != 3 {
		return ""
	}
	payload, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		return ""
	}
	var claims struct {
		Sub string `json:"sub"`
	}
	if json.Unmarshal(payload, &claims) != nil {
		return ""
	}
	return claims.Sub
}

// ServeHTTP translates and streams one request. The path after /genai is the Developer API path.
func (p *Proxy) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	in := "/" + r.PathValue("path")
	target, err := Translate(p.Project, p.Location, in)
	if err != nil {
		http.Error(w, err.Error(), http.StatusNotFound)
		return
	}
	token, err := p.Tokens.Token(r.Context())
	if err != nil {
		http.Error(w, "gateway credentials: "+err.Error(), http.StatusBadGateway)
		return
	}
	upstream := p.Upstream
	if upstream == "" {
		upstream = BaseURL(p.Location)
	}
	base, err := url.Parse(upstream)
	if err != nil {
		http.Error(w, "upstream url: "+err.Error(), http.StatusInternalServerError)
		return
	}
	actor := Subject(r.Header.Get("x-goog-api-key"))
	if actor == "" {
		actor = "unknown"
	}
	started := time.Now()
	status := 0
	rp := &httputil.ReverseProxy{
		Rewrite: func(pr *httputil.ProxyRequest) {
			pr.SetURL(base)
			pr.Out.URL.Path, pr.Out.URL.RawPath = target, ""
			pr.Out.Header.Del("x-goog-api-key")
			pr.Out.Header.Set("Authorization", "Bearer "+token)
		},
		Transport:     p.Transport,
		FlushInterval: -1,
		ModifyResponse: func(resp *http.Response) error {
			status = resp.StatusCode
			return nil
		},
		ErrorHandler: func(w http.ResponseWriter, _ *http.Request, err error) {
			status = http.StatusBadGateway
			http.Error(w, "vertex: "+err.Error(), http.StatusBadGateway)
		},
	}
	rp.ServeHTTP(w, r)
	log.Printf("vertex-proxy actor=%s call=%s status=%d dur=%s", actor, strings.TrimPrefix(in, "/"), status, time.Since(started).Round(time.Millisecond))
}
