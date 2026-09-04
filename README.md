# Farmenta · Contracts

Solidity contracts for Farmenta — borrow USDG against Uniswap v4 LP position NFTs on
Robinhood Chain (chain id 4663).

Specification: [`farmenta-defi/docs`](https://github.com/farmenta-defi/docs) →
`ARCHITECTURE.md` v0.3. **The spec is the source of truth.** Where this repo and the spec
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
  constants/RobinhoodChain.sol   deployed addresses (spec §18)
  interfaces/                    minimal external interfaces
test/
  base/       ForkTest (pinned-block harness), Fixtures (real pools and hooks)
  unit/       no network
  fork/       pinned-block reads against live Uniswap v4 state
  invariant/  invariant and fuzz campaigns
```

## Tests

Three lanes, matching how CI runs them:

| Command | What runs | Network |
|---|---|---|
| `make test` | unit tests | no |
| `make test-fork` | fork tests at the pinned block | yes |
| `make test-deep` | everything, long fuzz/invariant campaigns | yes |
| `make addresses` | asks every address on-chain what it is | yes |

CI runs the fast lane on every push and the deep lane on PRs to `main` plus nightly.

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

- `FarmentaMarket` is **immutable** — no proxy, no upgrade path. A bug in it is fixed by
  deploying a new market and migrating, not by patching.
- The **owner can replace `PositionValuer`, `CollateralPolicy` and `InterestRateModel` at
  any time, with no delay.** The valuer decides every position's value, so whoever holds
  the owner key can move every borrower's health factor. This is a deliberate trade: the
  market itself cannot be upgraded, so a valuation bug would otherwise be unfixable. It is
  not an acceptable posture for real deposits, and a timelock is the obvious next step.
- The owner can `pause`, and pausing halts liquidations too. Robinhood Chain publishes no
  Chainlink L2 Sequencer Uptime Feed, so pausing is the only sequencer-downtime mitigation
  available (spec §5.2, §15.1).
- Robinhood Chain is L2BEAT **Stage 0** with 2 validators; the sequencer can filter
  transactions. "A liquidation can always be submitted" is an assumption, not a guarantee.

## License

MIT. Note that `lib/v4-core` is BUSL-1.1 until 2027-06-15 — Farmenta uses the official
PoolManager deployment and never deploys its own. Revert v4lend is BUSL-1.1 as well and is
referenced for its patterns only; no code is copied from it.
