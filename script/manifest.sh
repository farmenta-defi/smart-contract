#!/usr/bin/env bash
# Builds deployments/<chainid>.json from the broadcast log of script/Deploy.s.sol.
#
#   script/manifest.sh [chainid] [broadcast log] [output]
#
#   chainid         4663
#   broadcast log   broadcast/Deploy.s.sol/<chainid>/run-latest.json
#   output          deployments/<chainid>.json
#
# Run it after `forge script script/Deploy.s.sol --broadcast`. The addresses come from the
# `Deployment` that `run()` returns, and each contract's `startBlock` from the receipt that
# created it. The script cannot write the block itself: on Robinhood Chain, an Arbitrum Orbit
# chain, `block.number` reports the L1 block (ARCHITECTURE §14); the receipts carry the L2 one.
#
# The output has the shape `indexer/config/deployment.ts` loads (`collateralPolicy`,
# `twapRecorder` and `markets`, each `{address, startBlock}`), with every other contract next to
# them in the same shape for the keeper, the backend and the frontend. For the indexer, copy it
# to `indexer/deployments/<name>.json` and set FARMENTA_DEPLOYMENT=<name>.
#
# It stops, writing nothing, on a dry-run log, a log for another chain, a failed transaction,
# or an address that no receipt created.
set -euo pipefail

chain_id="${1:-4663}"
log="${2:-broadcast/Deploy.s.sol/${chain_id}/run-latest.json}"
out="${3:-deployments/${chain_id}.json}"

command -v jq >/dev/null || { echo "manifest: jq is required" >&2; exit 1; }
[[ -f "$log" ]] || { echo "manifest: no broadcast log at $log" >&2; exit 1; }
case "$log" in */dry-run/*) echo "manifest: $log is a simulation; broadcast first" >&2; exit 1 ;; esac

mkdir -p "$(dirname "$out")"
jq --argjson chainId "$chain_id" -f /dev/stdin "$log" > "$out.tmp" <<'JQ' || { rm -f "$out.tmp"; exit 1; }
def fail($m): error("manifest: " + $m);
def number: ltrimstr("0x") | ascii_downcase | explode
  | reduce .[] as $c (0; . * 16 + (if $c >= 97 then $c - 87 else $c - 48 end));
def isZero: test("^0x0*$");

.receipts as $receipts
| if .chain != $chainId then fail("log is for chain \(.chain), not \($chainId)") else . end
| if ($receipts | length) == 0 then fail("log has no receipts; was it broadcast?") else . end
| if any($receipts[]; .status != "0x1") then fail("a transaction in the log failed") else . end

# The field order of Deploy.Deployment. script/Deploy.s.sol says to keep the two in step, and
# a count that differs stops here rather than shifting every name by one.
| ["timelock", "twapRecorder", "collateralPolicy", "priceOracle", "positionValuer",
   "interestRateModel", "marketImplementation", "blueChipMarket", "memeMarket",
   "blueChipLens", "memeLens", "blueChipLiquidatorHelper", "memeLiquidatorHelper",
   "owner", "policyAcceptOperation"] as $fields
| ((.returns["0"].value // fail("log has no returned Deployment"))
   | ltrimstr("(") | rtrimstr(")") | split(", ")) as $values
| if ($values | length) != ($fields | length)
  then fail("Deployment has \($values | length) fields, expected \($fields | length)") else . end
| ([$fields, $values] | transpose | map({key: .[0], value: .[1]}) | from_entries) as $d

# A contract not deployed (the timelock with DEPLOY_TIMELOCK=false, the helpers off 4663) is null.
| def contract($name):
    $d[$name] as $a
    | if ($a | isZero) then null
      else (first($receipts[] | select((.contractAddress // "" | ascii_downcase) == ($a | ascii_downcase))) // null)
        | if . == null then fail("no receipt created \($name) at \($a)") else . end
        | {address: $a, startBlock: (.blockNumber | number)}
      end;

{
  chainId: $chainId,
  owner: $d.owner,
  collateralPolicy: contract("collateralPolicy"),
  twapRecorder: contract("twapRecorder"),
  markets: {blueChip: contract("blueChipMarket"), meme: contract("memeMarket")},
  timelock: contract("timelock"),
  policyAcceptOperation: (if ($d.policyAcceptOperation | isZero) then null else $d.policyAcceptOperation end),
  priceOracle: contract("priceOracle"),
  positionValuer: contract("positionValuer"),
  interestRateModel: contract("interestRateModel"),
  marketImplementation: contract("marketImplementation"),
  lenses: {blueChip: contract("blueChipLens"), meme: contract("memeLens")},
  liquidatorHelpers: {blueChip: contract("blueChipLiquidatorHelper"), meme: contract("memeLiquidatorHelper")}
}
| if .collateralPolicy == null or .twapRecorder == null or .markets.blueChip == null or .markets.meme == null
  then fail("the policy, the recorder and both markets must be deployed") else . end
JQ
mv "$out.tmp" "$out"
echo "manifest: wrote $out"
