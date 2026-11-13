# GraphQL and BOLA: background

What GraphQL is, why it makes Broken Object Level Authorization (BOLA) easy to get wrong, and why existing tools do not fix it. Start here if you are new to either topic.

---

## 1. First principles: how the hole gets made

### 1.1 One endpoint instead of many

An API is the set of doors through which outside code asks a backend for data.

REST gives you many doors. `/users/5`, `/orders/124`, `/products/9`. Each door serves one fixed thing, the server decides what comes back, and the address itself announces what is being asked for.

GraphQL replaces all of them with one. You POST to a single `/graphql` endpoint with a query describing exactly which fields you want — from which object, and from which connected objects — and get back exactly that shape.

That single design choice is the origin of everything that follows, including the vulnerability.

### 1.2 The "graph" is a map, not a storage format

This is the single most misunderstood point, and it matters because the vulnerability lives in it.

Using GraphQL does **not** mean your data is stored as a graph. It still sits in ordinary relational tables, exactly as before. What the schema does is turn the silent number-links between those tables into **named paths you can walk**.

In the database:

```
users.id = 1
orders.owner_id = 1     ← a real link, but invisible: just a number in a column
```

In the schema:

```graphql
type User {
  name: String
  orders: [Order]       ← the same link, now a named, walkable edge
}

type Order {
  total: Float
  product: Product
  owner: User
}
```

The schema **is** the graph, written as text. Each field whose type is another object type is an edge.

### 1.3 A query is a traversal

Because the schema is a graph, a query is a path through it:

```graphql
{
  user(id: 1) {         # start at a User node
    name
    orders {            # walk the "orders" edge
      total
      product {         # walk the "product" edge
        name
      }
    }
  }
}
```

You start somewhere, follow connections, and pick up fields at each stop. One request, walking wherever the connections lead. Behind the scenes each "walk" is an ordinary database lookup, but the client never thinks about tables.

**This is the whole idea of GraphQL, and it is also the whole problem.**

### 1.4 Why REST moved here at all

Worth knowing, because it explains why the industry adopted something with this flaw. REST had four real problems, and on mobile they hurt:

| Problem | What it means |
|---|---|
| Over-fetching | You ask for a name, you get thirty fields. You paid to download twenty-nine you did not want. |
| Under-fetching | User, then orders, then products = three sequential round trips, each waiting on the last. |
| Endpoint sprawl | Every new screen needs a slightly different mix, so the backend writes another endpoint. They pile up. |
| Versioning | Change something, break old clients, ship v2. v1 lives forever. |

Facebook hit all four building their mobile app in 2012. GraphQL genuinely fixes all four. That is why GitHub, Shopify, PayPal, Netflix, Airbnb and others adopted it. The flaw is a side effect of the fix, not a reason the fix was wrong.

---

## 2. The vulnerability in detail

### 2.1 The structural consequence

In REST, one call touches one object. The question "does this caller own it?" has one obvious place to live, and the URL tells any intermediary what is being requested.

In GraphQL, one request touches many objects along many paths. **Every single one of them needs the same question asked.**

GraphQL does not ask it. Not as a bug — by design. The specification is deliberately unopinionated about authorization and the official guidance pushes it into the business-logic layer. There is no default safety net.

So the check must be hand-written inside every resolver that loads an object. A real API has thousands of resolvers.

### 2.2 BOLA

**Broken Object-Level Authorization.** Ranked **#1 in the OWASP API Security Top 10 (API1:2023)**, a position it has held since 2019. Known as **IDOR** in the older web-application context — same root cause, different name.

The attack:

1. The attacker is a **real, logged-in user** with a valid account and a valid token. Authentication passes correctly.
2. They copy the query the site normally sends for their own data:
   `{ order(id: 124) { total shippingAddress } }`
3. They change one number:
   `{ order(id: 125) { total shippingAddress } }`
4. The resolver confirms *who they are*, then fetches order 125. **It never checks ownership.**
5. A stranger's data comes back. They script it — 1, 2, 3, 4 — and scrape every customer.

The attacker is not breaking in. They are a legitimate user abusing valid access.

**Authentication works. Authorization is what breaks.**

### 2.3 Why GraphQL amplifies it specifically

- One query traverses many nodes and edges, so one request touches many resolvers.
- **Each resolver that loads an object by ID is its own separate authorization checkpoint.** Missing the check on any single one creates a hole.
- The graph's interconnection creates **multiple traversal paths to the same node**. A developer guards the obvious route and forgets the sideways one.
- The frontend is not a boundary. The query is visible in DevTools, and anyone can skip the browser entirely with curl or Postman. The server cannot distinguish a request from the official frontend from one typed by hand.

### 2.4 Evidence it is real

- **107 confirmed BOLA reports** classified from bug bounty disclosures, 2021–2026 (Kaur taxonomy). GraphQL global IDs systematically exploited via decode → increment → re-encode.
- **Shopify** paid a **US$5,000** bounty for an IDOR on GraphQL billing queries (HackerOne #2207248).
- **Airline booking API, 2026.** An autonomous red-team agent started with nothing but a URL. It read client-side JavaScript, minted an anonymous session, mapped the schema, found unprotected resolvers, and confirmed mass extraction of a major airline's booking database — with read *and write* access over active itineraries. **Fifteen minutes, zero human guidance.**
- **Escape, 2023.** Scanned 1,500+ public endpoints, found 46,000+ issues reachable without logging in, ~10% critical, ~40% broken access control. Leaked data included passport details and cloud tokens.

**An important nuance.** A 2025 industry report found no GraphQL-specific breaches in one quarter — but attributed this to **detection gaps rather than safety**, because a single dynamic endpoint obscures visibility for traditional controls. The apparent silence is itself evidence for the problem.

**Accuracy note:** describe these as documented *vulnerabilities and disclosures* — responsible-disclosure findings, bounties, CVEs — not confirmed criminal breaches with public victim counts.

---

## 3. Why it is still unsolved

There are only three places this could be fixed, and each fails for a specific reason.

| Where | The approach | Why it fails |
|---|---|---|
| **Inside the backend** | Write the ownership check in every resolver. The official advice, and what everyone does. | Fails for a human reason, not a technical one. It requires a thousand developers to write a flawless check in a thousand places and never once forget. That is not a security strategy — it is a guarantee of eventual failure. |
| **At the perimeter** | A WAF or API gateway is the natural chokepoint. | A WAF reads flat text and URLs. GraphQL sends one nested POST to one address. The firewall cannot parse the structure, cannot see which objects are requested, and even if it could, has no idea who owns what. |
| **Before deployment** | GraphQLer, PrediQL, taint analysis, scanners. | They find real flaws — in a test lab. Nothing protects a running system, and any flaw the tester misses stays fully exploitable. |

### 3.1 The near misses

**Apollo GraphOS Router** does parse the query — it is the leading commercial GraphQL gateway with built-in authorization. But it enforces **roles and scopes**. It can answer *"does this user hold `read:profiles`?"* It cannot answer *"does this user own order 124?"* Expressing ownership as roles means one role per object — role explosion. It also requires schema directives, which means modifying the backend, and an Enterprise licence.

**Hasura** genuinely enforces row-level ownership (`{ "id": { "_eq": "X-Hasura-User-Id" } }`). But **Hasura is the backend**, not a gateway. It generates the API from the database, so it controls the query — that is the only reason it can enforce anything. You cannot put Hasura in front of an existing Node or Java GraphQL server. You would have to replace the server. And every rule is hand-configured per table.

**OPA** parses GraphQL to an AST and evaluates policy per request — but policies are hand-written in Rego, it normally runs inside the server, it does not undo alias or fragment disguises, and it does not look up ownership by itself.

### 3.2 The gap, in one line

> **Nobody enforces per-object ownership at the perimeter, in front of a backend they do not control.**
