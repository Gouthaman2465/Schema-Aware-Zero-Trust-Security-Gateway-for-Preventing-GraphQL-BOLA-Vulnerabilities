# Roadmap and scope

Object-ownership enforcement is the primary goal. Because the gateway already parses and walks the whole query, a few structural defences cost almost nothing to add in the same pass. Injection, business-logic and data-layer problems stay out of scope, because they need backend knowledge that a perimeter cannot see.

| Item | Verdict | Notes |
|---|---|---|
| Depth, field-count and introspection limits | **Done** | Part of the existing pass. |
| Distinct-object budget per request | Planned | Defends against batched BOLA, where hundreds of ids go in one request. |
| Cross-request enumeration detection | Planned | Track failed ownership checks per caller. A caller who probes many other users' objects gets blocked. Needs a shared store such as Redis to work across several gateway instances. |
| Egress error sanitisation | Planned | Strip stack traces and "Did you mean ...?" hints from backend errors. |
| Path-wise enforcement for nested id-bearing fields | Planned | Today only root fields are resolved. See [Known issues](../README.md#known-issues). |
| Tests for the normaliser and enforcer | Planned | |
| Schema-derived input validation | Optional | Secondary. |
| Per-user cost-based rate limiting | Optional | A basic version only. Doing it properly is a project of its own. |
| Volumetric DDoS protection | **Out of scope** | Wrong layer. Use a CDN or network edge. |
| Signature-based injection detection | **Out of scope** | It would repeat the approach that the [literature survey](literature-survey.md) criticises. |

## Positioning

> Object-ownership enforcement is the primary contribution. Because the gateway already performs full AST normalisation and traversal, a set of structural defences are enforced in the same pass at negligible additional cost. Injection, business-logic and data-layer concerns remain out of scope by design, as they require backend semantics the perimeter cannot observe.

This answers the obvious question, "is this a BOLA gateway or a general GraphQL WAF?". It is a BOLA gateway. General GraphQL WAFs such as Inigo and Escape already exist.
