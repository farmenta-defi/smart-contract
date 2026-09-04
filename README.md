# Farmenta · Contracts

Solidity contracts for Farmenta — borrow USDG against Uniswap v4 LP position NFTs on
Robinhood Chain (chain id 4663).

Specification: [`farmenta-defi/docs`](https://github.com/farmenta-defi/docs) →
`ARCHITECTURE.md` v0.4. **The spec is the source of truth.** Where this repo and the spec
disagree, the spec wins and the code is wrong — except for addresses, which live in exactly
two places: spec §18 and `src/constants/RobinhoodChain.sol`, kept in sync by a test.

> **Status: pre-alpha.** Not audited, not deployed, not usable. Do not send funds anywhere
> derived from this code.

## Setup

```bash
git clone --recursive git@github.com:farmenta-defi/smart-contract.git
cd smart-contract
cp .env.example .env      # fill in ROBINHOOD_RPC_URL
make build
make test                 # unit tests, no network
make test-fork            # fork tests, needs the RPC key
```

Cloned without `--recursive`? Run `git submodule update --init --recursive`.

### Why the RPC has to be an archive endpoint

Fork tests pin a block so their results stay reproducible. The public RPC
(`rpc.mainnet.chain.robinhood.com`) keeps roughly **10–25 minutes** of state history —
`eth_getStorageAt` beyond that returns `metadata is not found` — so it cannot serve a pinned
fork. It is also DNS-hijacked by some ISPs, and `anvil` has no equivalent of curl's
`--resolve`. Alchemy's free tier is verified to work and is what `.env.example` points at.

## Layout

```
src/
  CollateralPolicy.sol           which pools may back a loan, on what terms (spec §4.5, §6)
  PositionValuer.sol             values a position at oracle prices (spec §4.2, §5.1)
  constants/RobinhoodChain.sol   deployed addresses (spec §18)
  interfaces/                    ICollateralPolicy, IPositionValuer, IPriceOracle, IAggregatorV3
  libraries/                     PositionAmounts, PriceMath, HookPermissions, TierPresets
test/
  base/       ForkTest (pinned-block harness), Fixtures (real pools, hooks, positions),
              PositionMinter (mints positions in the fork for shapes the chain lacks)
  mocks/      MockPriceOracle — settable prices, so the oracle can move while the pool cannot
  unit/       no network
  fork/       pinned-block reads against live Uniswap v4 state
  invariant/  properties asserted across arbitrary call sequences
script/
  DiscoverPositions.s.sol        finds real positions to use as fixtures
  InspectPositions.s.sol         prints everything the valuer reads, for one position
```

## Tests

Three lanes, matching how CI runs them:

| Command | What runs | Network |
|---|---|---|
| `make test` | unit tests | no |
| `make test-fork` | fork tests at the pinned block | yes |
| `make test-deep` | everything, long fuzz/invariant campaigns | yes |
| `make addresses` | asks every address on-chain what it is | yes |

The invariant campaign earns its place: it found a real bug. `setFrozen` judged whether a
pool could reopen by the threshold in force, but a ramp that has not started yet still reads
as its starting value — so a pool could be unfrozen moments before ramping below max LTV, and
every loan taken in that window was liquidatable the instant the ramp landed. No unit test
reached that ordering. The remaining invariants worth stating — the vault stays solvent, a
user action never leaves a loan at HF < 1, a liquidator is never paid more than
`repay × (1 + bonus)` (spec §16 Phase 1) — are properties of `FarmentaMarket`, and follow it.

CI runs the fast lane on every push and the deep lane on PRs to `main` plus nightly.

### `block.number` lies here

Robinhood Chain is an Arbitrum Orbit chain, so `block.number` reports the **L1** block, not
the L2 block — and Foundry versions disagree about whether a fork surfaces that. Never
assert on it, and never use it for timing: interest accrual and the TWAP window are defined
on `block.timestamp` (spec §5.3, §7). Fork tests assert they are at the pinned block by
checking a state fact instead (`PositionManager.nextTokenId()`).

### Fixtures

Two kinds, both needed. **Real positions** owned by strangers (reached with `vm.prank`)
prove valuation matches the messy real world — odd ranges, live hooks, genuinely accrued
fees. **Minted positions** created inside the fork cover what the chain does not happen to
contain: single-tick ranges, 1-wei liquidity, out-of-range on both sides. Real positions
alone leave the edges untested; minted ones alone only test cases we already imagined.

### `make addresses` earns its keep

On 2026-08-26 the frontend carried an ETH/USD feed address with wrong middle digits whose
*truncated* form still matched the docs, so reading it side by side looked correct. Humans
cannot see that class of error; the chain can. Every address is checked by asking the
contract something only it can answer — a feed's `description()`, a token's `symbol()`, a
periphery contract's immutable pointer back to the PoolManager — never by comparing one
hard-coded constant against another.

## Trust assumptions

Stated plainly, because the MVP is neither audited nor timelocked:

- **`FarmentaMarket` is UUPS upgradeable, and the owner can upgrade it at any time with no
  delay.** The market custodies collateral NFTs and holds USDG deposits, so whoever holds
  the owner key can replace its entire logic — including taking everything — in a single
  transaction, without warning. This is the largest risk in the protocol. It is accepted
  only because the MVP has no real TVL; a timelock on `_authorizeUpgrade` (with `pause`
  exempt so emergencies stay instant) is required before real funds. Spec §4.1, §15.
- Only the market sits behind a proxy. `PositionValuer`, `PriceOracle`, `CollateralPolicy`
  and `InterestRateModel` are plain contracts held as immutables and changed by upgrading —
  every extra proxy doubles the storage-collision surface without adding a capability.
- The owner can `pause`, and pausing halts liquidations too. Robinhood Chain publishes no
  Chainlink L2 Sequencer Uptime Feed, so pausing is the only sequencer-downtime mitigation
  available (spec §5.2, §15.1).
- Robinhood Chain is L2BEAT **Stage 0** with 2 validators; the sequencer can filter
  transactions. "A liquidation can always be submitted" is an assumption, not a guarantee.

## License

MIT. Note that `lib/v4-core` is BUSL-1.1 until 2027-06-15 — Farmenta uses the official
PoolManager deployment and never deploys its own. Revert v4lend is BUSL-1.1 as well and is
referenced for its patterns only; no code is copied from it.
