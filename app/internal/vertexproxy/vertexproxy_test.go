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

package vertexproxy

import (
	"context"
	"encoding/base64"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestTranslate(t *testing.T) {
	got, err := Translate("p", "global", "/v1beta/models/gemini-3.8-flash:streamGenerateContent")
	if err != nil || got != "/v1/projects/p/locations/global/publishers/google/models/gemini-3.8-flash:streamGenerateContent" {
		t.Fatalf("got %q, %v", got, err)
	}
	if _, err := Translate("p", "global", "/upload/v1beta/files"); err == nil {
		t.Fatal("non-model paths must be refused")
	}
	if BaseURL("us-central1") != "https://us-central1-aiplatform.googleapis.com" || BaseURL("global") != "https://aiplatform.googleapis.com" {
		t.Fatal("base url")
	}
}

func TestSubjectReadsActorJWT(t *testing.T) {
	payload := base64.RawURLEncoding.EncodeToString([]byte(`{"sub":"actor/workshop/adk1","iss":"x"}`))
	if got := Subject("h." + payload + ".s"); got != "actor/workshop/adk1" {
		t.Fatalf("sub = %q", got)
	}
	if Subject("placeholder") != "" {
		t.Fatal("a plain string is not a JWT")
	}
}

func TestProxyRewritesAuthAndStreams(t *testing.T) {
	var gotPath, gotAuth, gotKey, gotQuery, gotBody string
	up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotPath, gotAuth, gotKey, gotQuery = r.URL.Path, r.Header.Get("Authorization"), r.Header.Get("x-goog-api-key"), r.URL.RawQuery
		b, _ := io.ReadAll(r.Body)
		gotBody = string(b)
		w.Header().Set("Content-Type", "text/event-stream")
		_, _ = io.WriteString(w, "data: {\"candidates\":[]}\n\n")
	}))
	defer up.Close()
	p := &Proxy{Project: "p", Location: "global", Upstream: up.URL, Tokens: TokenFunc(func(context.Context) (string, error) { return "tok", nil })}
	mux := http.NewServeMux()
	mux.Handle("/genai/{path...}", p)
	gw := httptest.NewServer(mux)
	defer gw.Close()

	req, _ := http.NewRequest(http.MethodPost, gw.URL+"/genai/v1beta/models/gemini-3.8-flash:streamGenerateContent?alt=sse", strings.NewReader(`{"contents":[]}`))
	req.Header.Set("x-goog-api-key", "placeholder")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	body, _ := io.ReadAll(resp.Body)
	resp.Body.Close()
	if resp.StatusCode != 200 || !strings.Contains(string(body), "candidates") {
		t.Fatalf("resp = %d %s", resp.StatusCode, body)
	}
	if gotPath != "/v1/projects/p/locations/global/publishers/google/models/gemini-3.8-flash:streamGenerateContent" || gotQuery != "alt=sse" {
		t.Fatalf("upstream path=%q query=%q", gotPath, gotQuery)
	}
	if gotAuth != "Bearer tok" || gotKey != "" || gotBody != `{"contents":[]}` {
		t.Fatalf("auth=%q key=%q body=%q", gotAuth, gotKey, gotBody)
	}

	resp, err = http.Post(gw.URL+"/genai/v1beta/files", "application/json", nil)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusNotFound {
		t.Fatalf("non-model path = %d", resp.StatusCode)
	}
}
