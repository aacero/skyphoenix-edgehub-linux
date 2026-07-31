---
name: rest-openapi
description: Design and review REST-style HTTP APIs and OpenAPI 3.x descriptions — resources, methods, status codes, pagination, versioning, errors, and spec structure. Use when creating or changing an HTTP API contract, writing or reviewing an OpenAPI document, or evaluating API compatibility.
license: Proprietary
metadata:
  status: complete
  kind: domain
  last-reviewed: "2026-07-18"
---

# REST / OpenAPI

## Trigger

Load this skill when the task involves: designing or changing HTTP API endpoints; writing, generating, or reviewing an OpenAPI 3.x document; assessing backward compatibility of an API change; defining API error, pagination, or versioning conventions.

## Scope

Resource-oriented HTTP API design (methods, status codes, headers, idempotency), API contract evolution, and the structure of OpenAPI 3.x descriptions. Grounded in the OpenAPI Specification and HTTP semantics (RFC 9110).

## Non-goals

- GraphQL, gRPC, SOAP, and event/async API design (AsyncAPI).
- Gateway/product-specific configuration (rate-limit plugins, vendor policies) — vendor docs govern.
- Authentication protocol internals (OAuth 2.x/OIDC flows) beyond declaring them in the spec — cite the relevant RFCs/vendor docs.

## Official-source policy

Consult these before relying on this file, and prefer current official docs over this file:

- OpenAPI Specification (latest): https://spec.openapis.org/oas/latest.html (verified, accessed 2026-07-18 — latest published version at access time: 3.2.0, published 2025-09-19).
- HTTP semantics: RFC 9110 (https://www.rfc-editor.org/rfc/rfc9110 — canonical RFC editor URL; existence well-established, not re-fetched on access date).

If the role executing this skill lacks the `web` tool (only the `deep-researcher` and `market-opportunity-researcher` roles hold it), it must not cite official-source claims from memory. Instead, it requests the lookup as a deep-researcher task via the orchestrator, per `agent-framework/canonical/policies/research-policy.md`, and marks the item `UNKNOWN` until the research report returns.

## Version awareness

Identify which OpenAPI version the project targets before advising — tooling support lags the spec. Verified version lines at access date: 3.0.x, 3.1.x, and 3.2.0 (latest, per spec.openapis.org above). Notable: 3.1 aligned Schema Objects with modern JSON Schema; do not apply 3.0-era schema idioms (e.g., `nullable`) to 3.1+ documents without checking the target version's spec text. Also identify the API's own version/compatibility policy before proposing changes.

## Required citations

Spec-structure claims must cite the OpenAPI spec version the project uses; HTTP-semantics claims (method safety/idempotency, status-code meaning, caching/conditional requests) must cite RFC 9110 or its successors. Tooling behavior claims cite the tool's official docs.

## Terminology

Verified terms: resource, collection, representation; safe and idempotent methods; status-code classes (2xx/3xx/4xx/5xx); `ETag`/conditional requests; content negotiation; OpenAPI Document, `info`, `servers`, `paths`, Path Item, Operation, Parameter, Request Body, Responses, Components, Schema Object, Security Scheme, `$ref`.

## Common workflows

1. **Contract-first design.** Model resources and their identifiers; map operations to methods respecting HTTP semantics (GET safe, PUT/DELETE idempotent, POST for non-idempotent creation/actions); choose status codes by RFC-defined meaning, including error classes.
2. **OpenAPI authoring.** One source-of-truth document; shared shapes in `components` with `$ref`; every operation has success and error responses with schemas; examples for non-obvious payloads; security schemes declared and applied per-operation; lint/validate the document with the project's chosen validator and record the result.
3. **Error design.** A single documented error envelope (consider RFC 9457 Problem Details); machine-readable error codes; no internal details (stack traces, SQL) in responses.
4. **Pagination and filtering.** Pick one pagination style per API (cursor- or offset-based), document limits and defaults, and represent it consistently in parameters and responses.
5. **Versioning and compatibility.** Define what is a breaking change (removing/renaming fields, tightening validation, changing semantics) vs. additive; additive evolution preferred; breaking changes require a new version and a documented deprecation window. Diff old vs. new spec at review time.
6. **Contract testing.** Validate implementations against the OpenAPI document (request/response validation in tests or middleware); treat spec drift like failing CI.

## Integration boundaries

APIs described here typically front application services and are consumed by web/mobile clients, partner systems, integration platforms (e.g., iPaaS/RPA tools), and generated SDKs. The OpenAPI document is the contract artifact consumed by codegen, gateways, and test tooling — changes to it are public-contract changes under the scope-control policy.

## Verification checklist

- [ ] Target OpenAPI version identified; document validates cleanly (validator + result recorded)
- [ ] Methods respect HTTP safety/idempotency semantics; status codes RFC-correct
- [ ] Every operation documents error responses and the shared error envelope
- [ ] Pagination/filtering conventions consistent across the API
- [ ] Security schemes declared and applied; no unauthenticated surprise endpoints
- [ ] Compatibility assessed: change classified additive vs. breaking, with version/deprecation handling
- [ ] Spec matches implementation (contract test or validation evidence)

## References

See `references/SOURCES.md` in this skill's directory for official URLs and access dates.

## Last reviewed: 2026-07-18 (status: complete)
