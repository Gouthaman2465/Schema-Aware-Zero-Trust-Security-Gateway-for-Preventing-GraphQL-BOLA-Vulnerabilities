# How to run

Two parts: a deliberately **vulnerable backend** (`vulnshop/`) and the
**gateway** (`gateway/`) that protects it. Run every command below from the repository root.

## Quick start

```bash
# Terminal 1 — the vulnerable backend
cd vulnshop
pip install -r requirements.txt
python app.py                 # http://localhost:8000

# Terminal 2 — the gateway
cd gateway
pip install -r requirements.txt
python app.py                 # http://localhost:9000
```

Then:

- **http://localhost:8000** — the app with no protection (attacks leak here).
- **http://localhost:9000** — the same app through the gateway (attacks blocked,
  your own data still works).

## The users

| User | Token | Owns order |
|---|---|---|
| Goutham (id 1) — the attacker | `token-goutham` | 101 |
| Kumar (id 2) | `token-kumar` | 102 |
| Martin (id 3) | `token-martin` | 103 |

## How the two fit together

There is **one web app**, served by the backend. The gateway does not have its
own copy — it proxies the page through and guards the GraphQL endpoint:

```
browser ---> :9000 gateway  ---> :8000 backend ---> SQLite
                (checks)            (no checks)
browser ---> :8000 backend ---------------------> SQLite
```

Three things make this work, and nothing else is needed:

1. **The page calls a relative URL.** `static/index.html` does
   `fetch("/graphql")`, never `fetch("http://localhost:8000/graphql")`. So the
   same HTML talks to whichever port you loaded it from: open it on :9000 and
   it posts to the gateway, open it on :8000 and it posts straight to the
   backend. That one relative path *is* the integration.
2. **The gateway proxies the page.** `GET /` and `GET /static/...` are fetched
   from the backend and returned unchanged, so :9000 serves the same UI.
3. **The token rides along.** The browser sends
   `Authorization: Bearer token-<name>`; the gateway reads it, uses it to ask
   the backend "who is this?" and "who owns this object?", then forwards the
   original request with that same header.

The page shows which one you are on, top right: green *through the gateway
:9000* or red *direct to the backend :8000*.

## Order of startup

Start the backend first. If you start the gateway first it now waits up to 20
seconds for the backend and then connects, so either order works — but it
needs the backend's schema to build the ownership map before it can serve
anything.

## Things that will bite you

- **Port already in use** (`WinError 10048`) — an old copy is still running.
  Find and kill it:
  ```powershell
  netstat -ano | Select-String ":9000.*LISTENING"
  taskkill /F /PID <the pid>
  ```
  If Python runs under a versioned name such as `python3.12.exe`, then
  `taskkill /IM python.exe` will not find it. Kill by PID.
- **The gateway's own console is at :9000/graphql** (open it in a browser).
  It is a page the gateway serves; it POSTs your query to `/graphql` so every
  check still runs. The gateway never *executes* a GET: the backend would
  happily run `GET /graphql?query=...`, so proxying GET would be a hole
  straight past the ownership checks. `curl` on that URL still gets a 405.
- **You changed `database.py` and the gateway blocks your own data.** The
  gateway caches who owns what for 30 seconds (`CACHE_TTL_SECONDS`). Wait it
  out or restart the gateway after reseeding.
- **Everything returns `not found` on :9000.** That is the uniform refusal. The
  gateway says the same thing for "does not exist", "not yours" and
  "could not decide", so an attacker cannot tell them apart.

## The one-line demo

```bash
# Goutham tries to read Martin's order 103.

# Straight to the backend — leaks:
curl -s http://localhost:8000/graphql -H "Content-Type: application/json" \
  -H "Authorization: Bearer token-goutham" \
  -d '{"query":"{ order(id:103){ shippingAddress } }"}'

# Through the gateway — blocked:
curl -s http://localhost:9000/graphql -H "Content-Type: application/json" \
  -H "Authorization: Bearer token-goutham" \
  -d '{"query":"{ order(id:103){ shippingAddress } }"}'
```

## Typing queries in a browser

Open **http://localhost:9000/graphql** — the gateway serves Strawberry's own
GraphiQL there. The page is proxied from the backend, but it posts to the URL it
was loaded from, so every query you run goes through the gateway's checks.

Set your identity once in the **Headers** tab at the bottom of the editor:

```json
{ "Authorization": "Bearer token-goutham" }
```

Then run a query (Ctrl+Enter):

```graphql
{ order(id:103){ id total shippingAddress owner { name email } } }
```

On :9000 you get `{"errors":[{"message":"not found"}]}`. Change the header to
`Bearer token-martin` and the same query returns the order, because 103 is his.
The backend's own GraphiQL at **http://localhost:8000/graphql** leaks it for
either token.

**GraphiQL will say it cannot fetch the schema, and that is correct.** Its Docs
panel and autocomplete come from an introspection query, which the gateway
blocks — the official playground cannot enumerate the schema through the
gateway. Queries you type still run. If you want autocomplete while developing,
set `ALLOW_INTROSPECTION = True` in `gateway/config.py` and restart the gateway;
ownership is still enforced, but you have given up the introspection defence,
so turn it back off before demoing.

There is also a plain console at
**http://localhost:9000/static/playground.html** with a user dropdown and
one-click example attacks. It needs no header editing and prints a green
*BLOCKED by the gateway* or red *LEAKED* verdict, which reads better in front of
an audience.

## The whole demo at once

```powershell
.\scripts\demo.ps1
```

Needs Windows PowerShell and both servers running. Runs every attack against both ports and prints `LEAKED` in red for the
unprotected backend and `BLOCKED` in green for the gateway, then checks that
legitimate requests still work.

Each folder has its own README with the full details and attack list.

- [`vulnshop/README.md`](../vulnshop/README.md): the vulnerabilities and how to trigger each.
- [`gateway/README.md`](../gateway/README.md): how the gateway works and what it blocks.
