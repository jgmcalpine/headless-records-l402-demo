#!/usr/bin/env bash
# End-to-end L402 buyer demo: an agent hits a paid endpoint, receives a 402
# Lightning challenge, pays it via lnget from the buyer lnd node, retries
# with the L402 token, and receives real SEC insider data with provenance.
#
# Pacing: each step waits for enter so a recording can linger exactly as long
# as each beat needs. DEMO_PAUSE=0 ./demo.sh runs full speed (CI/transcripts);
# pauses are also skipped automatically when stdin is not a terminal.
#
# Prerequisites (see README.md):
#   - ./init.sh has completed (channel buyer -> seller is active; aperture
#     proxies to the bundled mock upstream, so no external API is needed)
#   - lnget is installed (go install from a clone of lightninglabs/lnget)
set -euo pipefail
cd "$(dirname "$0")"

TICKER="${DEMO_TICKER:-ACME}"
MAX_COST_SATS="${DEMO_MAX_COST_SATS:-50}"
PAUSE="${DEMO_PAUSE:-1}"

pause() {
  if [ "$PAUSE" = "1" ] && [ -t 0 ]; then
    read -rsp $'\n' _ || true
  fi
}

step() {
  printf '\n\033[1m════ %s ════\033[0m\n' "$1"
  pause
}

die() { printf 'demo failed: %s\n' "$*" >&2; exit 1; }

command -v jq >/dev/null || die "jq is required"
LNGET="$(command -v lnget || true)"
[ -n "$LNGET" ] || LNGET="$HOME/go/bin/lnget"
[ -x "$LNGET" ] || die "lnget not found on PATH or in ~/go/bin (see README)"

set -a
# shellcheck disable=SC1091
. ./.env
set +a
proxy="http://localhost:${APERTURE_PORT:-8081}"
url="$proxy/v1/ticker/$TICKER/insider-selling-summary"
summary_price="${SUMMARY_PRICE_SATS:-5}"
transactions_price="${TRANSACTIONS_PRICE_SATS:-10}"

curl -sf "$proxy/health" >/dev/null \
  || die "API not reachable through aperture at $proxy — is the stack up? run ./init.sh"

# Demo-local lnget home: config, paid tokens, nothing under the user's real
# ~/.lnget. Points lnget at the buyer lnd node's mapped gRPC port and creds.
lnget_home="$PWD/.lnget-home"
mkdir -p "$lnget_home/tokens"
buyer_macaroon="$PWD/volumes/lnd-buyer/data/chain/bitcoin/regtest/admin.macaroon"
[ -f "$buyer_macaroon" ] || die "buyer macaroon missing — run ./init.sh first"
cat > "$lnget_home/config.yaml" <<EOF
l402:
  max_cost_sats: ${MAX_COST_SATS}
  max_fee_sats: 10
  auto_pay: true
output:
  format: json
  progress: false
ln:
  mode: lnd
  lnd:
    host: localhost:${BUYER_GRPC_PORT:-10010}
    tls_cert: $PWD/volumes/lnd-buyer/tls.cert
    macaroon: $buyer_macaroon
    network: regtest
tokens:
  dir: $lnget_home/tokens
events:
  enabled: false
EOF
lnget() { "$LNGET" --config "$lnget_home/config.yaml" --logfile "$lnget_home/lnget.log" "$@"; }

# Fresh run: drop any cached token so the payment actually happens on camera.
lnget tokens clear --force >/dev/null 2>&1 || true

# The screen shows slimmed views; every full, untruncated response is
# appended here (fresh file per run).
transcript="$PWD/transcript.txt"
: > "$transcript"

step "Buyer node status (regtest)"
lnget ln status || die "buyer lnd node unreachable — run ./init.sh first"

step "STEP 1 — Unpaid request returns 402 + Lightning invoice"
echo "\$ curl -i $url"
challenge_headers="$(curl -s -D - -o /dev/null "$url")"
printf '== STEP 1: 402 challenge headers ==\n%s\n' "$challenge_headers" >> "$transcript"
printf '%s\n' "$challenge_headers" | head -1
# Truncate the macaroon hard; keep the invoice mostly visible — the lnbcrt
# prefix is the "this is a real Lightning invoice" signal.
printf '%s\n' "$challenge_headers" | grep -i '^Www-Authenticate: L402' \
  | sed -E 's/(macaroon=")([^"]{8})[^"]*/\1\2…/; s/(invoice=")([^"]{72})[^"]*/\1\2…/'

step "STEP 2 — lnget pays the invoice and retries automatically"
echo "\$ lnget --max-cost $MAX_COST_SATS $url"
body_file="$(mktemp)"
lnget --max-cost "$MAX_COST_SATS" -q "$url" > "$body_file"
echo "payment sent from buyer lnd node; response received"

step "STEP 3 — The purchased L402 token (macaroon + preimage), now cached"
lnget tokens list

step "STEP 4 — Real SEC data with provenance, bought for ${summary_price} sats"
# Slim view sized to fit one screen at recording font size: every summary
# value is kept, but largest_sale and the source ref render as one-line
# strings. The full response is in the transcript.
{ echo "== STEP 4: insider-selling-summary response =="; jq . "$body_file"; } >> "$transcript"
jq '{
  ticker,
  summary: (.summary | .largest_sale =
    (if .largest_sale then
      "\(.largest_sale.shares) sh @ \(.largest_sale.price) = \(.largest_sale.value) — \(.largest_sale.insider_name), \(.largest_sale.transaction_date)"
     else null end)),
  source: (if .sources[0] then (.sources[0] | "form \(.form) — accession \(.accession_number)") else null end),
  caveat: .caveats[0],
  request_id
}' "$body_file"
caveat_total="$(jq '.caveats | length' "$body_file")"
echo "(showing 1 of ${caveat_total} caveats — full response + provenance fields in transcript.txt)"
pause

step "STEP 5 — A DIFFERENT PRODUCT: insider-transactions (${transactions_price} sats) vs. the summary above (${summary_price} sats)"
printf '┌───────────────────────────┬─────────┐\n'
printf '│ %-25s │ %3s sat │\n' "insider-selling-summary" "$summary_price"
printf '│ %-25s │ %3s sat │\n' "insider-transactions" "$transactions_price"
printf '└───────────────────────────┴─────────┘\n'
echo "\$ lnget $proxy/v1/ticker/$TICKER/insider-transactions"
tx_file="$(mktemp)"
lnget --max-cost "$MAX_COST_SATS" -q \
  "$proxy/v1/ticker/$TICKER/insider-transactions" > "$tx_file"
{ echo "== STEP 5: insider-transactions response =="; jq . "$tx_file"; } >> "$transcript"
paid_sats="$(lnget tokens list | jq -r '.[0].amount_sat')"
echo "→ ${paid_sats} sats paid — vs ${summary_price} for the summary. Different endpoint, different price."
jq -c '{ticker, transaction_count: (.transactions | length), request_id}' "$tx_file"

step "STEP 6 — SAME endpoint again: cached token reused, NO new payment"
echo "\$ lnget $proxy/v1/ticker/$TICKER/insider-transactions"
echo "(watch for what's missing: no 'paying...' line — the token from step 5 is reused)"
repeat_file="$(mktemp)"
lnget --max-cost "$MAX_COST_SATS" -q \
  "$proxy/v1/ticker/$TICKER/insider-transactions" > "$repeat_file"
{ echo "== STEP 6: repeated insider-transactions response =="; jq . "$repeat_file"; } >> "$transcript"
jq -c '{ticker, request_id}' "$repeat_file"
rm -f "$body_file" "$tx_file" "$repeat_file"

total_sats=$((summary_price + transactions_price))
printf '\n→ 2 products, per-endpoint pricing, %s sats total, zero accounts, zero API keys.\n' "$total_sats"
