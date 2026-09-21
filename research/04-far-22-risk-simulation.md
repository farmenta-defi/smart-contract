# FAR-22 risk-parameter simulation

All measurements use Robinhood Chain fork block `54_200_000`. Reproduce the arithmetic
with `make simulate-risk`; reproduce the end-to-end liquidation path with:

```text
forge test --match-path test/fork/MarketMemeLiquidate.t.sol --match-test test_flashDumpReportsAttackEconomics -vv
```

## §6.2 parameter matrix

| Parameter | Blue-chip | Meme | Measurement / conclusion |
|---|---:|---:|---|
| max LTV | 65% | 30% | Preset read from `TierPresets`; no contract parameter changed |
| liquidation threshold | 75% | 40% | Collateral drop from max LTV to LT: 13.33% / 25% |
| liquidator bonus | 5% | 10% | Net after protocol fee: 4.5% / 9% |
| debt cap per pool | 500,000 USDG | 20,000 USDG | Cap is not a flash-dump defense; the crash branch prices seizure at spot |
| minimum debt | 10 USDG | 10 USDG | Compared against measured gas and 1% routing slippage |
| minimum position value | $50 | $50 | Position floor is debt floor divided by max LTV |
| spot/oracle gate | ±2% | min(spot, TWAP) | Meme liquidation uses the real recorder/oracle path in the fork test |
| counted fees | 10% of principal | 10% of principal | Position valuation remains uncapped; market applies the policy cap |
| reserve factor | 15% | 25% | Preset values are unchanged |
| reserve floor | 1% | 2.5% | Rug results below report lender loss after the floor |

## Chainlink history

The script reads all 1,992 rounds using `getRoundData`, from round `2^64 + 1` through
`2^64 + 1,992` (90.8 days). It reports the number of max-LTV health-factor crossings,
the max drawdown, and worst 1-hour and 24-hour drawdowns. The corrected collateral
buffer is `1 - maxLTV / LT`, not the inverse ratio.

## Liquidator economics

The fork test measures the actual `liquidate` call and prints ETH sold, USDG acquired,
repaid debt, gas, bad debt, and signed attacker PnL at 26% and 35% price drops. The
observed liquidation gas is approximately 256k–322k in the current harness; the script
uses the pinned block's `block.basefee`, not a hand-written gas price.

## Rug depths

The simulation evaluates 50%, 75%, 90%, and 99% collateral drawdowns using the meme
preset and prints bad debt and lender loss after reserves. No tier preset or on-chain
risk parameter is modified by FAR-22.
