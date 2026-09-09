# Muse hosted OAuth diagnosis, September 9, 2026

Author: Oliver Ames

## Outcome

Fixed and deployed to `https://mcp.applecore.app`. Muse omitted `resource` from its authorization request. After Connection ID routing, the Mac rejected the missing resource before loading client metadata or rendering approval. The Worker now defaults only an omitted resource to `https://mcp.applecore.app/mcp` on authorization GET and token POST. It preserves explicitly supplied values, including empty or incorrect values, for rejection by the Mac.

Deployment version: `ca81b82a-7f3d-4f06-a781-9faaf9681bef`.
Tracking: https://github.com/oliverames/apple-core/issues/11

## Failing request and evidence

The user supplied the browser URL from the failure reported around September 9, 2026, 16:11 UTC. Its endpoint was `GET https://mcp.applecore.app/oauth/authorize`, with these parameters:

| Parameter | Supplied value |
| --- | --- |
| `response_type` | `code` |
| `client_id` | Signed URL under `https://mcp.applecore.app/clients/`, containing client name `Muse`, the callback below, and authentication method `none` |
| `redirect_uri` | `https://agent.meta.ai/api/hatch/oauth/callback` |
| `scope` | `mcp` |
| `state` | Present; session-specific value retained only in the conversation |
| `code_challenge_method` | `S256` |
| `code_challenge` | Present, 43-character URL-safe challenge |
| `connection` | Present, valid 32-character Connection ID; retained only in the conversation |
| `resource` | **Absent** |

The full original URL remains in the conversation rather than this public repository. A controlled live reproduction used the same callback, supplied Connection ID, a fresh DCR result, and diagnostic state/PKCE values. Without `resource`, it returned HTTP 400 and the exact reported JSON. Adding only the canonical resource returned HTTP 200 and the Mac approval form. This identifies the failed guard as `let resource = values["resource"]` inside `validatedAuthorizationRequest`.

The earlier probes without a Connection ID did not exercise Mac authorization validation. The supplied failing URL already contained a Connection ID, so it had advanced past the routing form.

## Every source and route for the exact error

`Invalid OAuth authorization request.` occurs only twice in the repository, both in `App/Services/Serving/AppleCoreHTTPServer.swift`:

- `oauthAuthorizeForm`: native `GET /oauth/authorize` when `validatedAuthorizationRequest(query)` returns nil.
- `oauthApproveAuthorization`: native `POST /oauth/authorize` when `validatedAuthorizationRequest(form)` returns nil.

The shared validation returns nil under any of these conditions:

- `response_type` is missing or is not `code`.
- `code_challenge_method` is missing or is not `S256`.
- `client_id` or `redirect_uri` is missing.
- `code_challenge` is missing or empty.
- `resource` is missing or does not exactly match the Mac's advertised canonical MCP resource.
- For a URL client identifier, the requested redirect does not match the fetched client metadata.
- For an opaque identifier, no client exists or can be adopted, or its registered redirect list does not contain the requested redirect. Adoption requires an Apple Core-generated identifier and an allowed redirect URI.

The Worker does not generate that description. It can relay it on:

- `GET /oauth/authorize` after a nonempty, syntactically valid `connection` routes the request to a connected Mac.
- `POST /t/<connection>/oauth/authorize` after the hosted Origin check and any routed approval-token Connection ID check succeed.

Native metadata exceptions produce different errors. Missing `scope` alone does not produce this error. Worker DCR parsing errors and oversized authorization queries produce bare `invalid_request`, without this description.

## Historical log limitations

The deployed Worker settings were read through the Cloudflare API. They reported `observability: null`, `logpush: false`, and no tail consumers. The checked-in configuration explicitly disables observability.

A historical telemetry query for September 9, 2026, 16:06–16:16 UTC returned HTTP 403, Cloudflare code 10000, `Authentication error`. Historical requests were therefore not recovered. No claim about exact historical request headers, response logs, or server-side DCR parameters is made. Diagnosis relies on the supplied browser URL and fresh live reproduction.

## Compatibility and security

RFC 8707 section 2.1 permits a predefined default resource when the client omits the parameter: https://www.rfc-editor.org/rfc/rfc8707.html#section-2.1

MCP's November 25, 2025 authorization specification requires clients to send resource indicators in authorization and token requests: https://modelcontextprotocol.io/specification/2025-11-25/basic/authorization

Muse's request follows ordinary OAuth authorization-code/PKCE structure but omits this MCP-required field. The fixed default provides compatibility while retaining the same single token audience. Its server-side DCR and HTTPS callback were accepted without changes. Muse's actual token request was not observed; the same default on token POST prevents the corresponding omission from failing later.

The visible Connection ID UX, approval form, approval token, origin checks, redirect matching, PKCE, and native resource validation are unchanged. Approval POST obtains the canonical resource from the existing hidden form field. Revocation is unchanged.

## Verification

All three deployment builds passed. The complete hosted test suite passed 20 tests after allowing the local test runtime to bind its loopback listener. Initial sandbox execution failed with `listen EPERM`, not an assertion failure.

After deployment:

- Protected-resource metadata at both advertised paths and authorization-server metadata: HTTP 200, expected issuer, resource, endpoints, S256, and public-client authentication.
- DCR with Muse's callback and `scope=mcp`: HTTP 201 and a signed URL client identifier.
- Initial authorization without a Connection ID: HTTP 200, original routing form.
- Authorization with the supplied Connection ID and omitted resource: HTTP 200, Mac approval form.
- Authorization with the explicit canonical resource: HTTP 200.
- Explicit wrong/empty resource, missing PKCE challenge, wrong redirect, and malformed Connection ID: HTTP 400.
- Code and refresh token requests with omitted resource and deliberately nonexistent grants: `invalid_grant`, demonstrating successful resource validation without issuing tokens.
- The same token requests with explicit wrong/empty resource: `invalid_target`.

Isolated tests additionally verify forwarded state, callback, client ID, PKCE fields, canonical defaulting, preservation of explicit resources, and unchanged revocation semantics. The fixture Mac is a mock, so live negative checks establish actual Mac resource rejection.

No approval was submitted and no test grant was issued. DCR itself is stateless, but successful Mac authorization-form rendering adopts client metadata into the Mac's client list. The optional `muse-probe` cleanup was not performed. Full interactive Muse consent and successful token exchange remain for the user's fresh connect attempt.
