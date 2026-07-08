https://github.com/user-attachments/assets/af9d8e92-2531-4209-8b91-9d5eed3733a1

# L402 Demo — Pay-per-request SEC data over Lightning (regtest)

This repo is a self-contained demo of the full agent buyer/seller loop: an AI
agent pays for SEC data per request over the Lightning Network instead of
pre-registering an API key. Payment gating is done by
[Aperture](https://github.com/lightninglabs/aperture) (Lightning Labs' L402
reverse proxy); the buyer side uses
[lnget](https://github.com/lightninglabs/lnget) from
[lightning-agent-tools](https://github.com/lightninglabs/lightning-agent-tools).

**Everything here is regtest-only. No real funds, anywhere.**

The upstream API is a bundled **mock-upstream** container serving canned JSON
that matches the real Headless Records API's DTO shapes, so the whole
402 → pay → data loop runs from `./init.sh && ./demo.sh` with no external API,
no database, and no signup.

## Architecture

```
 buyer side (host)                     seller side (docker compose network)
 ─────────────────                     ─────────────────────────────────────
 demo.sh ─> lnget ──── gRPC :10010 ──> lnd-buyer ══ channel ══ lnd-seller
               │                           │        (10M sat)      │
               │                           └──── bitcoind ─────────┤
               │                                (regtest)          │ invoices +
               │                                                   │ L402 validation
               └───── HTTP :8081 ────> aperture ───────────────────┘
                    402 challenge /        │
                    L402 token             │ + x-l402-proxy-secret header
                                           v
                                   mock-upstream (compose network :3000)
                                   canned JSON, real DTO shapes
```

- **aperture** returns `402 Payment Required` + a Lightning invoice for the
  paid routes, validates paid L402 tokens (macaroon + payment preimage), and
  proxies authorized requests to the upstream with a shared-secret header.
- **lnd-seller** is aperture's node: it creates the invoices and receives the
  sats. **lnd-buyer** is the agent's wallet; lnget pays from it.
- **mock-upstream** never touches payments. It only checks the shared secret to
  know a request came through the proxy, and serves the canned response.

Paid routes (prices in [.env.example](.env.example)):

| Route | Price |
|---|---|
| `GET /v1/ticker/{ticker}/insider-selling-summary` | 5 sats |
| `GET /v1/ticker/{ticker}/insider-transactions` | 10 sats |

Public through the proxy (no payment): `/health`, `/ready`, `/openapi.json`,
`/.well-known/paid-api.json`, `/v1/ticker/{ticker}/preview`.

## Prerequisites

- Docker Desktop (on Apple Silicon the aperture image runs under Rosetta —
  it is amd64-only)
- `jq`, `envsubst` (`brew install jq gettext`)
- Go ≥ 1.23, to build lnget. **Note:** `go install …/lnget/cmd/lnget@latest`
  currently fails because lnget's `go.mod` contains `replace` directives.
  Build from a clone instead:

  ```bash
  git clone https://github.com/lightninglabs/lnget.git /tmp/lnget
  cd /tmp/lnget && go install ./cmd/lnget   # installs to ~/go/bin/lnget
  ```

## Quickstart

```bash
# 1. Bring up bitcoind + both lnd nodes + mock-upstream + aperture, fund the
#    buyer, open the buyer -> seller channel (idempotent, ~60s first run)
./init.sh

# 2. Run the full buyer loop
./demo.sh
```

No flags, no database, no API to start separately. `init.sh` runs
`docker compose up -d` for you and is safe to re-run.

`demo.sh` prints each step: the raw 402 challenge with the Lightning invoice,
lnget paying it from the buyer node, the cached L402 token
(payment hash + amount), and the final SEC JSON with provenance and caveat
fields — then demonstrates per-endpoint pricing and cached-token reuse.

Tear down with `docker compose down` (add `-v` and delete `volumes/` for a
fully fresh chain).

## Example run (full transcript)

<details>
<summary>Full output of one clean run (click to expand)</summary>
════ Buyer node status (regtest) ════

Backend: lnd
Status: connected
Node: 0396f96d9fcf6b55...
Alias: hr-buyer
Network: regtest
Synced: true
Balance: 49989995882 sats

════ STEP 1 — Unpaid request returns 402 + Lightning invoice ════

$ curl -i http://localhost:8081/v1/ticker/ACME/insider-selling-summary
HTTP/1.1 402 Payment Required
Www-Authenticate: L402 macaroon="AgEEbHNh…", invoice="lnbcrt50n1p4yajanpp552t2ad3dyz99qc7w86vatgzn446ps9lk00qvktrl7852vhp9pxss…"

════ STEP 2 — lnget pays the invoice and retries automatically ════

$ lnget --max-cost 50 http://localhost:8081/v1/ticker/ACME/insider-selling-summary
L402 payment required for localhost:8081, paying...
Payment complete, retrying request...
payment sent from buyer lnd node; response received

════ STEP 3 — The purchased L402 token (macaroon + preimage), now cached ════

localhost:8081 (paid)
  Payment Hash: 2c1e207e4923a54e...
  Amount: 5 sats
  Fee: 0 sats
  Created: 2026-07-08 15:14:12


════ STEP 4 — Real SEC data with provenance, bought for 5 sats ════

{
  "ticker": "ACME",
  "summary": {
    "transaction_count": 1,
    "sale_transaction_count": 1,
    "purchase_transaction_count": 0,
    "total_sales_value": "825.00",
    "total_purchase_value": "0.00",
    "net_sales_value": "825.00",
    "total_shares_sold": "55",
    "unique_insiders_selling": 1,
    "unique_insiders_buying": 0,
    "largest_sale": "55 sh @ 15.00 = 825.00 — John Sample, 2026-04-27"
  },
  "source": "form 4 — accession 0000001002-26-000001",
  "caveat": "Insider selling is not necessarily negative.",
  "request_id": "req_mock_0000000000006"
}
(showing 1 of 6 caveats — full response + provenance fields in transcript.txt)


════ STEP 5 — A DIFFERENT PRODUCT: insider-transactions (10 sats) vs. the summary above (5 sats) ════

┌───────────────────────────┬─────────┐
│ insider-selling-summary   │   5 sat │
│ insider-transactions      │  10 sat │
└───────────────────────────┴─────────┘
$ lnget http://localhost:8081/v1/ticker/ACME/insider-transactions
L402 payment required for localhost:8081, paying...
Payment complete, retrying request...
→ 10 sats paid — vs 5 for the summary. Different endpoint, different price.
{"ticker":"ACME","transaction_count":1,"request_id":"req_mock_0000000000007"}

════ STEP 6 — SAME endpoint again: cached token reused, NO new payment ════

$ lnget http://localhost:8081/v1/ticker/ACME/insider-transactions
(watch for what's missing: no 'paying...' line — the token from step 5 is reused)
{"ticker":"ACME","request_id":"req_mock_0000000000008"}

→ 2 products, per-endpoint pricing, 15 sats total, zero accounts, zero API keys.
</details>

## The bundled mock upstream

The upstream is [mock-upstream/server.py](mock-upstream/server.py) — a single
stdlib-Python file on a stock `python:3.12-alpine` image. It serves the two
gated routes plus the public utility routes with canned JSON **captured
verbatim from the real API** (synthetic seeded ACME data), so DTO shapes —
summary, sources, caveats, request IDs — match production exactly; request IDs
are prefixed `req_mock_` so mock responses are always identifiable. It also
mirrors the real API's proxy-secret gating (401 without the aperture-injected
header) and is not port-mapped to the host, so the payment boundary story is
unchanged.

The recording above runs against this bundled mock upstream, so the exact loop is fully reproducible on any machine — no signup, no real API key, no external network calls beyond the regtest containers themselves.

## Pricing configuration

Prices are per-service in the rendered aperture config. Edit
`SUMMARY_PRICE_SATS` / `TRANSACTIONS_PRICE_SATS` in `.env`, then re-render and
restart aperture:

```bash
./init.sh                       # re-renders volumes/aperture/aperture.yaml
docker compose restart aperture
```

Each paid route is its own `services:` entry in
[aperture.yaml.template](aperture.yaml.template), so endpoints can be priced
independently. (The committed template is placeholder-only; the rendered
config with the real secret lives under gitignored `volumes/`.)

## Security model

**What the shared secret does.** Aperture injects
`x-l402-proxy-secret: <value>` into every request it proxies to a paid
service. The upstream accepts paid-route requests only with that header. This
prevents the L402 tier from being bypassed by calling the backend directly —
payment can't be skipped by going around the proxy.

**What it does not protect against:**

- A leaked secret: anyone holding it can impersonate the proxy. Rotation
  requires re-rendering the aperture config and restarting both processes.
- Per-buyer accountability: the upstream sees only "came through aperture", not
  which buyer paid. Buyer identity/limits live in aperture's tokens.
- Network-level protections: in this demo aperture serves plain HTTP
  (`insecure: true`) — fine for regtest, unacceptable for real deployments.

**Why regtest.** The demo must be reproducible, free, and safe: regtest mines
its own blocks on demand, coins are valueless, and `--noseedbackup` (auto-
created, unencrypted wallets) is acceptable. Nothing in `volumes/` is worth
protecting; it is still gitignored so no macaroons/certs/seeds ever land in
git.

**What would change for signet/mainnet (described, not implemented):**

- Real lnd nodes with seed backups, encrypted wallets, and channel liquidity
  management; aperture's node needs inbound liquidity to receive.
- TLS everywhere: aperture with `autocert` + a real domain instead of
  `insecure: true`; lnd TLS certs with proper SANs; no `-k`/insecure flags.
- A bakery-restricted macaroon for aperture (`invoice.macaroon` only, never
  admin) and a pay-only macaroon for the buyer agent.
- Replace the static shared secret with network isolation (upstream reachable
  only from aperture's network) or mTLS between proxy and backend; add
  secret rotation.
- Real pricing/treasury decisions: invoice expiry, token TTL (`timeout`),
  per-service `capabilities`, and monitoring for stuck HTLCs/channels.

## Troubleshooting (observed failure modes)

1. **`lnget` install fails with "go.mod … contains replace directives".**
   `go install …@latest` cannot build lnget. Clone the repo and run
   `go install ./cmd/lnget` from inside it (see Prerequisites).

2. **`demo.sh` dies with "API not reachable through aperture".**
   Aperture proxies `/health` to the mock upstream, so this means the stack
   isn't up (or aperture is still restarting). Re-run `./init.sh` and wait for
   it to finish.

3. **Paying twice when alternating between the two paid endpoints.**
   Not a bug: aperture macaroons are scoped per service and lnget caches one
   token per domain, so switching endpoints buys a new token at that
   endpoint's price, while repeat calls to the same endpoint reuse the
   cached token (demo steps 5–6 show both). `lnget tokens list` shows what
   you hold; `lnget tokens clear --force` forces a fresh purchase.

4. **`init.sh` fails with "timed out waiting for chain sync" after the stack
   sat idle for a day or more.**
   Regtest chains only advance when you mine, and bitcoind reports
   `initialblockdownload: true` whenever the chain tip is older than ~24
   hours — which makes lnd report `synced_to_chain: false` forever. `init.sh`
   now mines a tip-refresh block on every run to clear this automatically;
   if you hit it anyway, mine one block manually and re-run init:
   `docker compose exec bitcoind bitcoin-cli -regtest -rpcuser=demo
   -rpcpassword=demo generatetoaddress 1 <any-address>`.

If aperture restarts in a loop right after `docker compose up`, it is usually
waiting for `lnd-seller` to finish creating its wallet/macaroons; it recovers
by itself within a few seconds (`restart: on-failure`).

## Part of the Headless Records project

- **[headlessrecords.dev](https://headlessrecords.dev)** — the product this demo gates
- **[OpenAPI spec](https://api.headlessrecords.dev/openapi.json)** — full API contract
- **[headless-records-mcp](https://github.com/jgmcalpine/headless-records-mcp)** — MCP server for agent access to the same API