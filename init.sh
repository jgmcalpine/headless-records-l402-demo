#!/usr/bin/env bash
# One-shot init for the L402 regtest demo:
#   1. creates .env (random shared secret) if missing
#   2. renders aperture.yaml from the template
#   3. starts the compose stack
#   4. mines regtest blocks, funds the buyer lnd node, opens a
#      buyer -> seller channel, and waits for it to become active
#
# aperture proxies paid requests to the bundled mock-upstream container, so
# the whole demo runs from `./init.sh && ./demo.sh` with no external API.
#
# Idempotent: safe to re-run; skips funding/channel steps that are done.
# REGTEST ONLY. No real funds anywhere.
set -euo pipefail
cd "$(dirname "$0")"

say() { printf '\n==> %s\n' "$*"; }
die() { printf 'init failed: %s\n' "$*" >&2; exit 1; }

command -v docker >/dev/null || die "docker is required"
command -v jq >/dev/null || die "jq is required"
command -v envsubst >/dev/null || die "envsubst is required (brew install gettext)"

# --- 1. .env -----------------------------------------------------------------
if [ ! -f .env ]; then
  say "Creating .env from .env.example with a random L402_PROXY_SECRET"
  secret="$(openssl rand -hex 16)"
  sed "s/^L402_PROXY_SECRET=replace-me$/L402_PROXY_SECRET=${secret}/" \
    .env.example > .env
fi
set -a
# shellcheck disable=SC1091
. ./.env
set +a
[ "${L402_PROXY_SECRET}" != "replace-me" ] || die "set L402_PROXY_SECRET in .env"

# --- 2. render aperture config -------------------------------------------------
say "Rendering aperture.yaml (prices: summary=${SUMMARY_PRICE_SATS} sats, transactions=${TRANSACTIONS_PRICE_SATS} sats)"
mkdir -p volumes/aperture volumes/lnd-seller volumes/lnd-buyer volumes/bitcoind
rendered_config="volumes/aperture/aperture.yaml"
tmp_config="$(mktemp)"
envsubst '${SUMMARY_PRICE_SATS} ${TRANSACTIONS_PRICE_SATS} ${L402_PROXY_SECRET}' \
  < aperture.yaml.template > "$tmp_config"
aperture_config_changed=0
cmp -s "$tmp_config" "$rendered_config" 2>/dev/null || aperture_config_changed=1
mv "$tmp_config" "$rendered_config"

# --- 3. start the stack --------------------------------------------------------
say "Starting docker compose stack"
docker compose up -d
if [ "$aperture_config_changed" = "1" ]; then
  say "Aperture config changed; restarting aperture"
  docker compose restart aperture >/dev/null 2>&1 || true
fi

btc() {
  docker compose exec -T bitcoind bitcoin-cli -regtest \
    -rpcuser="${BITCOIND_RPC_USER}" -rpcpassword="${BITCOIND_RPC_PASS}" "$@"
}
lncli_for() {
  local node="$1"
  shift
  docker compose exec -T "$node" lncli --network=regtest "$@"
}

wait_for() {
  local label="$1" attempts="$2"
  shift 2
  local i=0
  until "$@" >/dev/null 2>&1; do
    i=$((i + 1))
    [ "$i" -le "$attempts" ] || die "timed out waiting for ${label}"
    sleep 2
  done
}

say "Waiting for bitcoind and both lnd wallets"
wait_for "bitcoind rpc" 30 btc getblockchaininfo
wait_for "lnd-seller wallet" 60 lncli_for lnd-seller getinfo
wait_for "lnd-buyer wallet" 60 lncli_for lnd-buyer getinfo

# --- 4. fund buyer + open channel ---------------------------------------------
synced() { lncli_for "$1" getinfo | jq -e '.synced_to_chain == true'; }
active_channel() {
  lncli_for lnd-buyer listchannels | jq -e '.channels[] | select(.active == true)'
}

buyer_addr="$(lncli_for lnd-buyer newaddress p2wkh | jq -r .address)"

# Regtest chains only advance when mined. If the stack sat idle for >24h the
# tip goes stale, bitcoind reports initialblockdownload=true, and lnd never
# reports synced_to_chain — so every sync wait below would time out. One
# fresh block clears it.
btc generatetoaddress 1 "$buyer_addr" >/dev/null

has_channel() {
  lncli_for lnd-buyer listchannels | jq -e '.channels | length > 0'
}

if has_channel >/dev/null 2>&1; then
  # After a restart the channel exists but reports active=false until both
  # nodes resync and reconnect. Wait for reactivation instead of opening a
  # duplicate channel.
  say "Existing buyer -> seller channel found; waiting for it to become active"
  wait_for "chain sync (buyer)" 60 synced lnd-buyer
  wait_for "chain sync (seller)" 60 synced lnd-seller
  seller_pubkey="$(lncli_for lnd-seller getinfo | jq -r .identity_pubkey)"
  lncli_for lnd-buyer connect "${seller_pubkey}@lnd-seller:9735" >/dev/null 2>&1 || true
  wait_for "active channel" 60 active_channel
else
  confirmed_sats() {
    lncli_for lnd-buyer walletbalance | jq -e '(.confirmed_balance | tonumber) > 0'
  }
  if ! confirmed_sats >/dev/null 2>&1; then
    say "Mining 101 regtest blocks to the buyer wallet (coinbase maturity)"
    btc generatetoaddress 101 "$buyer_addr" >/dev/null
  fi
  wait_for "chain sync (buyer)" 60 synced lnd-buyer
  wait_for "chain sync (seller)" 60 synced lnd-seller
  wait_for "buyer confirmed balance" 60 confirmed_sats

  seller_pubkey="$(lncli_for lnd-seller getinfo | jq -r .identity_pubkey)"
  say "Connecting buyer -> seller (${seller_pubkey})"
  lncli_for lnd-buyer connect "${seller_pubkey}@lnd-seller:9735" >/dev/null 2>&1 || true

  say "Opening a 10,000,000 sat channel buyer -> seller"
  lncli_for lnd-buyer openchannel --node_key "$seller_pubkey" --local_amt 10000000 >/dev/null

  say "Mining 6 blocks to confirm the channel"
  btc generatetoaddress 6 "$buyer_addr" >/dev/null
  wait_for "active channel" 60 active_channel
fi

say "Channel state:"
lncli_for lnd-buyer listchannels | jq '.channels[] | {active, capacity, local_balance, remote_pubkey}'

cat <<EOF

Init complete. aperture proxies to the bundled mock upstream — no external
API needed. Run the end-to-end paid request demo:
  ./demo.sh
Aperture (plain HTTP, regtest) is listening on http://localhost:${APERTURE_PORT:-8081}
EOF
