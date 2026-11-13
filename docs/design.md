# Design

This document describes the **target design** of the gateway. The code in this repository implements part of it. Read the status table first.

| Part of the design | Status in this repo |
|---|---|
| Normalisation: aliases, fragments, variables, encoded global IDs | Implemented (variable *default values* are not read, see [Known issues](../README.md#known-issues)) |
| Cheap rejections: introspection, depth, field count, missing token | Implemented |
| Ownership inference from the schema | Implemented as a **keyword heuristic** (see `OWNERSHIP_WORDS` in `config.py`) |
| `UNRESOLVED` tier, blocked by default | Implemented |
| Runtime ownership probe with a time-based cache | Implemented (in-memory, not Redis) |
| Mutation ownership check before forwarding | Implemented |
| Uniform `"not found"` refusal | Implemented |
| Multi-path verification with taint propagation | **Not implemented.** Only id-bearing root fields are checked. |
| Distinct-object budget, cross-request enumeration detection | Not implemented (see [roadmap](roadmap.md)) |
| Egress error sanitisation | Not implemented |
| Redis cache, SDL as a schema source | Not implemented |
| Comparison against Apollo, Hasura, OPA | Not done |
| Automated tests | None yet |

---

## 1. What the system does

A reverse proxy that sits in front of any existing GraphQL server, inspects every request, and blocks it if the caller does not own an object somewhere in the query. The backend does not know it exists.

It is a **gateway**, not a framework. A framework is something you build *with* — you import it and write code against it. A gateway runs *in front of* an app as a separate process. That distinction is what gives you **zero backend modification**.

It is **language-independent**, and this is part of the novelty. The gateway speaks HTTP and GraphQL, not Python function calls. The backend may be Node, Java, Go, Ruby or .NET. By contrast, resolver checks, directives and middleware libraries are language-locked — a GraphQL Shield rule only works in JavaScript. In an organisation running several services in several languages, one gateway protects all of them.

### 1.1 Architecture

```
┌──────────────── PHASE A — SETUP, runs once at startup ─────────────────┐
│                                                                        │
│   Backend schema  ──►  Ownership inference  ──►  Ownership map         │
│   SDL / registry /      identify user type,       high / medium /      │
│   introspection         score edges, trace        UNRESOLVED tiers     │
│                         indirect paths                      │          │
└─────────────────────────────────────────────────────────────┼──────────┘
                                                              │
                  ┌─────────────────┐                         │
                  │ Client request  │                         │
                  └────────┬────────┘                         │
                           ▼                                  │
┌──────────── PHASE B — GATEWAY, runs on every request ───────┼──────────┐
│                                                             │          │
│   1. NORMALISE                                              │          │
│      inline fragments, strip aliases, resolve variables,    │          │
│      decode global IDs, expand batches                      │          │
│                           ▼                                 │          │
│   2. WALK                                                   │          │
│      type-aware AST traversal, path stack, taint flag       │          │
│                           ▼                                 │          │
│   3. VERIFY  ◄──────────────────────────────────────────────┘          │
│      classify each node, check ownership (cache → probe)               │
│                           ▼                                            │
│   4. VERDICT                                                           │
│      one failure rejects everything                                    │
└──────────────┬──────────────────────────────┬──────────────────────────┘
               ▼                              ▼
   ┌────────────────────────┐    ┌────────────────────────┐
   │   Backend server       │    │      Rejected          │
   │ receives clean request │    │  returns "not found"   │
   └────────────────────────┘    └────────────────────────┘
```

The arrow from the ownership map into step 3 is the join between the two phases. **That single connection is essentially the whole contribution:** automatic rule generation feeding automatic per-object enforcement.

### 1.2 Phase A — inferring the rules

**Step 1 — Identify the identity type.** Three heuristics in priority order:

1. **The `me` / `viewer` / `currentUser` root field.** Its return type is the identity type. Strongest signal, because the semantics are unambiguous — GitHub literally uses `viewer`.
2. **JWT claim mapping.** If the token carries `sub` or `user_id`, find a type with a matching `id` format.
3. **Naming fallback.** A type named `User`, `Account`, `Member`, `Customer`.

**Step 2 — Build the type graph.** Nodes are object types. Edges are fields whose type is another object type, labelled with the field name and recording cardinality and nullability. `Order.owner: User!` becomes `Order --owner--> User`.

**Step 3 — Score ownership edges.**

| Signal | Description | Confidence |
|---|---|---|
| **Reverse containment** | The identity type has a field returning `T` (e.g. `User.orders`). Anything reachable by walking outward from the user is that user's by construction. | ~0.95 — strongest |
| **Direct identity reference** | A field returning the identity type with an ownership-lexicon name: `owner`, `author`, `creator`, `customer`, `assignee`, `createdBy`. | ~0.90 |
| **Scalar foreign key** | A field named `ownerId`, `userId`, `authorId`. Naming convention only, but directly comparable to the caller's ID. | ~0.60 |
| **Transitive path** | BFS toward the identity type following only edges above threshold. Confidence = product of edge confidences. | Decays with length |

**Step 4 — Emit the map in three tiers.**

```yaml
Order:
  ownership_path: [owner, id]
  confidence: 0.92
  source: direct_identity_reference

Comment:
  ownership_path: [post, author, id]
  confidence: 0.71
  source: transitive_path

Product:
  ownership_path: null
  confidence: 0.0
  status: UNRESOLVED
```

- **High (≥ 0.85)** → enforce automatically
- **Medium (0.5–0.85)** → enforce, but log and surface for confirmation
- **Unresolved / low** → **fail closed**, or report-only during onboarding

**The `UNRESOLVED` bucket is the most important design decision in the system.** Inference is heuristic, not sound — it will miss things. The claim is not "we infer everything perfectly." It is *"we infer the mechanical majority and formally surface the rest as a reviewable checklist."* That turns an invisible problem into a visible one.

**Step 5 — Resolving actual ownership at runtime.** Inference gives you the *rule*. You still need the *fact*.

| Option | How it works | Trade-off |
|---|---|---|
| **(a) Pre-flight probe** *(use this)* | The gateway issues its own minimal query along the ownership path — `{ order(id:125) { owner { id } } }` — with a privileged service token, and compares to the caller's JWT. | Uses the backend's own graph. No DB credentials, works with any language. Costs a round trip; needs a privileged credential. |
| **(b) Ownership cache** *(use this)* | Cache probe results in Redis as `owner:Order:125 → user_8` with a TTL. | High hit rate, since objects are queried repeatedly. Must invalidate on ownership-changing mutations. |
| **(c) Query rewriting** | Inject a filter so the backend returns only owned rows (the Hofer technique). | Only works if the schema exposes filter arguments. Cite as related work. |
| **(d) Response-time verification** | Let it run, then inspect and strip the response. | **Unacceptable for mutations** — the side effect already happened. Defence-in-depth for queries only. |

**Decision: (a) + (b). For mutations, always probe before forwarding.**

### 1.3 Phase B — enforcing them

**Step 1 — Normalise.** Non-negotiable. You cannot analyse a query you cannot see clearly.

- **Fragment inlining** — replace every fragment spread with its selection set, recursively, including inline fragments. Add cycle detection.
- **Alias canonicalisation** — analyse under real field names. Detect alias multiplication (`a: order(id:1) b: order(id:2) c: order(id:3)`) — one request enumerating three objects, each needing its own check. This is the Directus CVE-2024-39895 class.
- **Variable resolution** — resolve `$x` against the `variables` JSON. **Skipping this bypasses the entire defence**, because real clients send IDs as variables by default.
- **Batch expansion** — the body may be a JSON array of operations, and a document may hold several.
- **Identifier normalisation** — handle `id:`, `ids: [..]`, `where: {id:}`, `filter: {}`, and decode Relay global IDs (base64 `Type:id`).

**Step 2 — Schema-aware traversal.** Walking the AST alone is insufficient; you must know what type each field returns. A field named `owner` is meaningless without knowing whether you are inside `Order` or `Comment`. In `graphql-core`, `TypeInfo` combined with `visit()` maintains type context as the visitor descends.

Maintain two structures during the walk: a **path stack** (`[viewer, orders, product, reviews]`) and an **ownership taint flag**.

**Step 3 — Classify every node.**

| Classification | Meaning | Action |
|---|---|---|
| **Anchored** | Path starts at `me`/`viewer` and every edge traversed was an ownership edge. Owned by construction. | No check. **This is the performance optimisation** — most legitimate traffic is anchored. |
| **Unanchored ID fetch** | A client-supplied ID names an object directly (`order(id: 125)`). | Must verify. Classic BOLA lives here. |
| **Lateral / back-reference** | Walking back up to a user or across into another user's data (`order.owner.email`). | Must verify. This is the "guarded one path, forgot another" failure. |
| **Collection** | Returns a set (`orders(first: 100)`). | Fine if anchored. A global root collection needs an enforced filter or denial. |

**Step 4 — Taint propagation.** The subtlest part, and the easiest to get wrong.

- Start: `tainted = true` at `me`/`viewer`, `false` at any other root field.
- Traversing an **ownership edge** → taint **preserved**.
- Traversing into a **shared/global type** (e.g. `Product`) → taint **dropped**.
- Traversing a **back-reference to an identity type** → taint **dropped**, node flagged lateral.
- Any node with `tainted == false` requesting a non-public field → **verify explicitly**.

Why this matters — consider `viewer → orders → product → reviews → author → email`. Your order is yours, but the *product* is shared. Without taint-dropping, an attacker anchors at `viewer`, hops through a shared object, and walks into a stranger's data while still appearing anchored. Structurally the same idea as taint analysis in program security (connecting to Lambers et al., ICGT 2024) — except applied **at runtime on the live request path**.

**Step 5 — Compose the verdict.**

- **Any single node fails → reject the entire request.** No partial execution, no field stripping — partial responses leak which objects exist.
- **Return a uniform error** — "not found", never "forbidden". Revealing that an object exists but is not yours is itself a disclosure. Same response for nonexistent objects, unowned objects, and unresolved types.
- **Emit a structured audit record** — node, path, object ID, rule fired, decision.
- **Forward the original request**, not the normalised one. The client expects its aliases honoured; normalisation was for analysis only.

### 1.4 The security-critical ordering

**Normalisation must fully complete before the walk.** If it misses anything — one fragment form, unresolved variables, undecoded global IDs — every later phase analyses the wrong query and the gateway is bypassable.

This is the one point where the system would fail silently, so it is the part that most needs tests.

### 1.5 Handling disabled introspection

Disabling introspection in production is standard advice, so the gateway must work without it.

| Option | Description |
|---|---|
| **SDL at deploy time** *(primary)* | The schema exists as a file in the backend repo. A CI/CD hook pushes it to the gateway on deploy. Better than introspection: works regardless of settings, available before traffic flows, and solves schema drift properly. |
| **Private introspection** | Introspection is disabled for *untrusted external clients*. The backend can permit it specifically from the gateway by IP allowlist or service token. |
| **Gateway as introspection boundary** | The elegant inversion: the backend keeps introspection on internally, and the **gateway blocks all introspection from outside**. A limitation becomes a feature, and it demos well. |
| **Schema registry** | In federated setups the schema already lives centrally. Pull from there. |

Implement this as a pluggable **schema source** interface. A small abstraction that lets the gateway run anywhere.

---

## 2. What is new

The claim is deliberately narrow:

> **Deriving ownership rules from the structure of the schema itself.**

Policy mining is a mature field, but established approaches derive rules from data that does not exist when a system is first deployed:

| Information source | Used by | Available at deployment? |
|---|---|---|
| Access logs | Karimi et al., most policy mining | **No.** A new system has none. Logs also record what users *did* do, so an existing BOLA flaw is learned as normal behaviour. |
| Existing ACLs | Bottom-up policy mining | **No.** Circular: it assumes the policy that is being created. |
| Written specifications | LLM-based policy generation | **No.** Such documents rarely exist. |
| **The schema's type structure** | No prior work found | **Yes.** Always available, via SDL or introspection. |

The four contributions:

1. **Automatic ownership inference from schema structure.** The least explored of the four, and the main one.
2. **Multi-path ownership verification.** Check every node along every traversal path, with taint propagation. Existing tools check the object fetched, not the routes taken to reach it. *(Designed, not yet implemented.)*
3. **Obfuscation-resistant normalisation.** Aliases, fragments, variable-carried IDs and encoded global IDs are resolved before policy evaluation.
4. **Zero backend modification.** Deterministic, at the perimeter, independent of the backend's language.

Contributions 2 to 4 are engineering built from known techniques. Contribution 1 is the new one.

### What this project does not claim

- It does not claim the problem is unknown.
- It does not claim that no gateway does GraphQL authorization. Apollo GraphOS Router does, for roles and scopes.
- It does not claim perfect inference. See the `UNRESOLVED` tier above.
- It does not claim coverage of injection, business-logic flaws or volumetric DDoS.

The positioning sentence: *gateways today enforce roles and scopes. Ownership enforcement exists only inside backend engines such as Hasura, which must replace the backend. No standalone gateway infers and enforces per-object ownership across an existing backend.*
