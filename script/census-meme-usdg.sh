#!/usr/bin/env bash
set -euo pipefail

block="${1:-54200000}"
log_rpc_url="${ROBINHOOD_LOG_RPC_URL:-https://robinhood.drpc.org}"
start=0
step=1000000
pool_manager="0x8366a39cc670b4001a1121b8f6a443a643e40951"
initialize="0xdd466e674ea557f56295e2d0218a125ea4b4f0f6f3307b95f85e6110838d6438"
usdg="0x0000000000000000000000005fc5360d0400a0fd4f2af552add042d716f1d168"

[[ "$block" =~ ^[0-9]+$ ]] || { echo "block must be a decimal integer" >&2; exit 2; }

while ((start <= block)); do
    end=$((start + step - 1))
    if ((end > block)); then end="$block"; fi

    for topic in 2 3; do
        topics="[\"$initialize\",null"
        if ((topic == 2)); then topics+=",\"$usdg\"]"; else topics+=",null,\"$usdg\"]"; fi
        payload=$(printf '{"jsonrpc":"2.0","id":1,"method":"eth_getLogs","params":[{"address":"%s","fromBlock":"0x%x","toBlock":"0x%x","topics":%s}]}' "$pool_manager" "$start" "$end" "$topics")
        curl --fail --silent --show-error --data "$payload" -H 'content-type: application/json' "$log_rpc_url" |
            jq -r 'if .error then error(.error.message) elif .result == null then error("missing result") else .result[]? | .topics[1] end'
    done

    start=$((end + 1))
done | sort -u
