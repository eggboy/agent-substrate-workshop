# Lab 2: Egress and credentials (20 min)

The agent in Lab 1 calls Gemini itself, from inside a sandbox that has no network by default. This
lab shows how the model call gets out, where the key is, and where it is not. Then the same agent
runs with no key at all.

## Approach A: a key the sandbox never sees

The template sets `GOOGLE_API_KEY=placeholder-replaced-by-egress-gateway`. The egress policy you applied
in Lab 1 ([`egress-adk.yaml`](../../manifests/egress-adk.yaml)) has two rules: plain HTTP to the gateway, and
HTTPS to `generativelanguage.googleapis.com` with a `replaceHeaders` effect that swaps the `x-goog-api-key`
header for the value of Secret `workshop-secrets/gemini`. The egress gateway terminates TLS for that
hostname (the actor trusts `egress-mitm.ate.dev` through the projected trust bundle) and re-originates the
call with the real key.

1. Look at what the actor can reach. Ask it to try three places:
   ```bash
   adk/scripts/turn.sh ws "Run these shell commands and paste their output verbatim: curl -sS -m 5 -o /dev/null -w HTTP%{http_code} https://example.com/ ; echo; curl -sS -m 5 -o /dev/null -w HTTP%{http_code} https://generativelanguage.googleapis.com/ ; echo; curl -sS -m 5 -o /dev/null -w HTTP%{http_code} http://gateway.workshop.svc.cluster.local/readyz ; echo"
   ```
   Expected: `curl: (6) Could not resolve host: example.com` (deny by default means no DNS answer, not a
   timeout); `HTTP404` from the Gemini host (reachable, `/` is just not a route); `HTTP200` from the gateway.
   The model declines to print `$GOOGLE_API_KEY` for you, which is fair; the next step reads it from the outside.
2. Prove the key is nowhere an attendee can read:
   ```bash
   kubectl ate get actor-template adk-v1 -a workshop -o yaml | grep -n GOOGLE_API_KEY
   kubectl ate get actor ws -a workshop -o yaml | grep -c AIza || echo "no key in the actor record"
   kubectl ate get egress-policy ws -a workshop -o yaml | grep -n credentialUri
   kubectl -n workshop-secrets get secret gemini -o jsonpath='{.data.key}' | wc -c    # the only place, base64
   ```
   The template holds the placeholder, the policy holds a URI (`ate-secret://k8s.io/default/workshop-secrets/gemini/key`),
   and the snapshot in the bucket holds the placeholder too, because that is what the process has in memory.
3. Who may read that Secret is a Substrate decision, not a Kubernetes RBAC one: the credential provider's
   policy maps atespaces to namespaces.
   ```bash
   kubectl -n ate-system get configmap k8s-credential-provider-namespace-policy -o jsonpath='{.data.namespace-policy\.yaml}'
   ```
4. Break it on purpose. Point the policy at a key that does not exist and watch the call fail closed, then restore it:
   ```bash
   sed 's#workshop-secrets/gemini/key#workshop-secrets/gemini/missing#' adk/manifests/egress-adk.yaml > /tmp/egress-broken.yaml
   make egress POLICY=/tmp/egress-broken.yaml ACTOR=ws
   sleep 10                                                              # the egress gateway caches policies for ~10 s
   adk/scripts/turn.sh ws "Reply with one word: hello"                   # [error] Forbidden 403 ... egress denied
   make egress POLICY=adk/manifests/egress-adk.yaml ACTOR=ws
   ```
   A missing or unauthorised credential is a 403 at the egress gateway: the request never leaves the cluster.
   `turn.sh` prints ADK's error event; the model call took 0.1 s to fail.

## Approach B: no key at all

`adk-vertex-v1` is the same image and agent with one change: `GOOGLE_GEMINI_BASE_URL` points at the gateway's
`/genai` route. The gateway translates each Developer-API call into the Vertex AI call for the same model and
authenticates with its own Workload Identity ([`internal/vertexproxy`](../../../app/internal/vertexproxy/vertexproxy.go)).
The actor's egress policy ([`egress-adk-vertex.yaml`](../../manifests/egress-adk-vertex.yaml)) has a single plain-HTTP
rule to the gateway, and its `replaceHeaders` puts a **Substrate-minted actor JWT** into the `x-goog-api-key`
header: the header that carried a shared secret in approach A now carries the caller's identity.

5. Create the template and an actor (`make adk-catch-up LAB=3` does the same). Creating a template needs a free
   worker for its golden-snapshot build, and so does a new actor; with two workers, suspend `ws` first unless the
   idle policy already did:
   ```bash
   kubectl ate suspend actor ws -a workshop 2>/dev/null; kubectl ate get workers -n workshop
   scripts/render.sh adk/manifests/template-adk-vertex-v1.yaml.tmpl | kubectl ate create actor-template -f -
   until kubectl ate get actor-template adk-vertex-v1 -a workshop -o json 2>/dev/null | jq -e '.status.goldenSnapshotStatus | (.goldenTag.name // .errorMessage)' >/dev/null; do sleep 2; done
   kubectl ate create actor wsv --template=adk-vertex-v1 -a workshop
   make egress POLICY=adk/manifests/egress-adk-vertex.yaml ACTOR=wsv
   ```
6. Same prompts, then read the gateway's log:
   ```bash
   adk/scripts/turn.sh wsv "Reply with exactly one word: vertex"
   adk/scripts/turn.sh wsv "Run: curl -sS -m 5 -o /dev/null -w HTTP%{http_code} https://generativelanguage.googleapis.com/ ; echo   and paste the output"
   kubectl -n workshop logs deploy/gateway --since=3m | grep vertex-proxy
   ```
   Expected: `vertex`, then `Could not resolve host` for the Gemini endpoint (this actor has no HTTPS rule at all),
   and gateway lines like `vertex-proxy actor=actor/workshop/wsv call=v1beta/models/gemini-3.8-flash:generateContent status=200 dur=1.9s`.
   Cloud Audit Logs attribute the Vertex calls to the gateway's service account; the per-actor attribution is
   the gateway's log line, from the JWT's `sub`.

## Which one would you deploy

| | A: injected API key | B: gateway proxy with Workload Identity |
|---|---|---|
| Secret in the sandbox | never (placeholder only) | none exists |
| Secret in a snapshot | never | none exists |
| Who the model provider sees | one key per Secret | one service account |
| Per-actor attribution | the egress gateway's access log | the gateway's log, from the actor JWT (verify it in production) |
| Quota and billing | Developer API tier of the key | Vertex AI, project quotas, Cloud Audit Logs |
| Extra moving part | the credential provider and its namespace policy | a path-translating proxy in the gateway |
| Streaming | through the MITM, flushed per event | through the proxy, flushed per event |

Approach A is the shortest path for a workshop and for teams on the Developer API. Approach B is what a
platform team ships: no key to rotate, identity instead of a shared secret, and audit logs on the model side.

## Checkpoint

```bash
make adk-verify LAB=2
```

**Stuck?** Run `make adk-catch-up LAB=3`.

Next: [Long-running sessions under interruption](../03-interruptions/README.md)
