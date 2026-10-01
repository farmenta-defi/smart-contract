# Farmenta · Contracts

Solidity contracts for Farmenta — borrow USDG against Uniswap v4 LP position NFTs on
Robinhood Chain (chain id 4663).

For protocol behavior, see the public [contract architecture](https://docs.farmenta.fun/docs/reference/architecture), [risk documentation](https://docs.farmenta.fun/docs/risk/overview), and [contract reference](https://docs.farmenta.fun/docs/reference/farmenta-market). The Solidity source and its tests define the behavior implemented by this repository. Network addresses are maintained in `src/constants/RobinhoodChain.sol` and checked by the address verification command.

> **Status: deployed and unaudited.** Contracts are deployed on Robinhood Chain (chain id 4663). This repository has not been audited; interacting with the protocol can result in loss of funds. Verify contract addresses against the [public address reference](https://docs.farmenta.fun/docs/reference/addresses).

## Admin powers and risks

Read the public [risk overview](https://docs.farmenta.fun/docs/risk/overview) and [owner powers](https://docs.farmenta.fun/docs/risk/admin-powers) before supplying assets or depositing collateral. Lending and liquidation are implemented; see [what `FarmentaMarket` does](#what-farmentamarket-does-today) for the current contract surface.

The deployment script assigns the markets and collateral policy to a `TimelockController`. The owner can still change protocol behavior, including through a market implementation upgrade. The owner timelock delay is two days, and market upgrades also pass through the market's own two-day upgrade timelock. A scheduled upgrade is bound to the implementation code hash and can be installed during a 14-day grace period after it becomes ready. The timelock delays admin authority; it does not remove it. Review pending operations and `pendingUpgrade()` before interacting.

Owner changes to pool terms can affect existing loans. Lowering a liquidation threshold can make a previously healthy loan liquidatable. Raising `removeHaircutBps` on a frozen pool can reduce recognized collateral value for existing loans. The reserve floor limits routine reserve withdrawals but can be changed by a future market upgrade. See [risk parameters](https://docs.farmenta.fun/docs/reference/risk-parameters), [protocol fees and reserves](https://docs.farmenta.fun/docs/concepts/protocol-fees-and-reserves), and [owner powers](https://docs.farmenta.fun/docs/risk/admin-powers) for details.

The guardian can act immediately to pause a market, freeze a pool, disable a token, or revoke a hook. A market pause also stops liquidations. Only the owner can reverse these actions; reopening therefore waits on the owner timelock in the standard deployment. Freezing a pool, disabling a token, and revoking a hook block new collateral and borrowing but do not prevent repayment, collateral withdrawal, fee collection, liquidity removal, or liquidation of existing positions. The guardian cannot move assets, change terms, withdraw reserves, or upgrade contracts.

The timelock and guardian have different roles: the timelock governs routine owner actions, while the guardian can stop new risk immediately. Review the [pause and emergency guide](https://docs.farmenta.fun/docs/risk/pause-and-emergency) for remaining risks and operational guidance.

This repository and its contracts have not been audited. Do not treat the timelock, reserve floor, or guardian as a guarantee against loss.

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
  FarmentaMarket.sol             custodies position NFTs, lends against them, liquidates
  CollateralPolicy.sol           which pools may back a loan, and on what terms
  PriceOracle.sol                reads policy-listed Chainlink USD feeds
  PositionValuer.sol             values a position at oracle prices
  MarketLens.sol                 read-only risk views for one market proxy
  constants/RobinhoodChain.sol   Robinhood Chain addresses
  interfaces/                    ICollateralPolicy, IPositionValuer, IPriceOracle, IAggregatorV3
  libraries/                     PositionAmounts, PriceMath, HookPermissions, TierPresets,
                                 MarketLedger, MarketDebt, MarketMint, MarketLiquidation, MarketLiquidity,
                                 MarketUpgrade, LiquidationMath, DebtMath
test/
  base/       ForkTest (pinned-block harness), Fixtures (real pools, hooks, positions),
              PositionMinter (mints positions in the fork for shapes the chain lacks),
              MarketForkTest (a market wired to real policy and valuer, mock oracle)
  mocks/      MockPriceOracle and MockAggregatorV3: settable prices for isolated valuation
              and Chainlink checks; MockERC20 — a 6-decimal asset for the vault off-fork
  unit/       no network
  upgrade/    the market's storage layout, slot by slot; no network
  fork/       pinned-block reads against live Uniswap v4 state
  invariant/  properties asserted across arbitrary call sequences
script/
  DiscoverPositions.s.sol        finds real positions to use as fixtures
  InspectPositions.s.sol         prints everything the valuer reads, for one position
  Deploy.s.sol                   deploys the whole protocol, owned by a TimelockController
  Timelock.s.sol                 schedules, executes or cancels one owner call on that timelock
  Upgrade.s.sol                  upgrades one market through its timelock: schedule(), then
                                 execute() two days later; deployReplacement() for a proxy
                                 owned by the TimelockController
```

`MarketDebt`, `MarketMint`, `MarketLiquidation`, `MarketLiquidity` and `MarketUpgrade` are linked
delegatecall libraries. Deploy and link them in order: `MarketDebt`, then `MarketMint` linked to
`MarketDebt`, then `MarketLiquidation`, then `MarketLiquidity` (fee claims) linked
to `MarketDebt`, then `MarketUpgrade` (the upgrade timelock, linked to nothing), then the market
implementation linked to all five. They
write only the market's ERC-7201 ledger namespace and preserve the market's caller, events,
and storage.
`MarketLens` is a separate read-only contract bound to one proxy, so deploy one lens for
each Blue-chip or Meme market and direct risk-view consumers to that lens.

## Deploying

`script/Deploy.s.sol` deploys everything in one run: the five linked libraries (forge deploys
them through the CREATE2 factory), `TwapRecorder`, `CollateralPolicy`, `PriceOracle`,
`PositionValuer`, `InterestRateModel`, one market implementation, the Blue-chip (`fUSDG-BC`) and
Meme (`fUSDG-MEME`) proxies, a `MarketLens` and a `LiquidatorHelper` for each, and a
`TimelockController` that owns both markets and the policy. It names the guardian on all three,
and configures USDG, WETH and native ETH with their Chainlink feeds. It lists no pool: listings
are curated one by one.

```sh
# simulate against mainnet; nothing is sent
FOUNDRY_PROFILE=deploy OWNER=0x… GUARDIAN=0x… forge script script/Deploy.s.sol --rpc-url robinhood
# broadcast
FOUNDRY_PROFILE=deploy OWNER=0x… GUARDIAN=0x… forge script script/Deploy.s.sol --rpc-url robinhood \
    --broadcast --private-key $PRIVATE_KEY
```

After the broadcast, build the address manifest from its log:

```sh
script/manifest.sh            # broadcast/Deploy.s.sol/4663/run-latest.json -> deployments/4663.json
```

It needs `jq`. Every contract gets `{address, startBlock}`; `collateralPolicy`, `twapRecorder`
and `markets.{blueChip,meme}` are exactly what `indexer/config/deployment.ts` loads, so the file
goes to `indexer/deployments/<name>.json` unchanged, and the keeper's `KEEPER_LOG_START_BLOCK` is
`collateralPolicy.startBlock`. `owner` and `guardian` are plain addresses: who owns the markets
and the policy, and who may pause and tighten at once. They are what the run set; a later
`setGuardian` is read from the contracts, not from this file. The blocks come from the receipts, not from the script:
`block.number` on this chain is the L1 block. The manifest names the fields of the
returned `Deployment` by position; `test_deploymentFieldOrderMatchesTheManifest` pins that
order. It refuses a dry-run log, a failed transaction, an address no receipt created, and a deployment
that names no guardian.

Commit the mainnet manifest (`deployments/4663.json`) together with its broadcast log: it is the
record the services read addresses from.

An `anvil` fork keeps chain id 4663, so a rehearsal against one leaves a
`broadcast/Deploy.s.sol/4663/` log that looks like a mainnet deploy: give `manifest.sh` another
output path, and delete that log afterwards.

The simulation stops before any transaction if `GUARDIAN` is unset or is the deployer, if an
external address has no code, if a Chainlink feed does not answer with a fresh price, or if the
wiring read back differs from what was deployed. Measured 2026-09-28 in a simulation against
mainnet: 23 transactions with `OWNER` apart from the deployer, 24 when the deployer is also the
proposer, and about 23.6 million gas (forge prints 30.7 million: it adds a 30% margin), a few
dollars at 0.02 gwei.

| Variable | Default on 4663 | Meaning |
|---|---|---|
| `OWNER` | the deployer | proposer and executor of the timelock; owner of everything when `DEPLOY_TIMELOCK=false`. Set it to a key other than the deployer's (a hardware key or a multisig): left at the default, the key in `.env` holds the whole timelock, and the run logs a warning |
| `GUARDIAN` | none, required | the account that may `pause` a market and, on the policy, `freeze` a pool, `disableToken` and `revokeHook`, at once. Refused when unset, `address(0)`, or the deployer |
| `DEPLOY_TIMELOCK` | `true` | `false` makes `OWNER` the direct owner |
| `TIMELOCK_MIN_DELAY` | `172800` (2 days) | the timelock's delay, in seconds; `0` is refused |
| `TIMELOCK_PROPOSER`, `TIMELOCK_EXECUTOR` | `OWNER` | the timelock's roles; neither may be `address(0)` |
| `DEPLOY_LIQUIDATOR_HELPERS` | `true` on 4663, `false` elsewhere | deploy one `LiquidatorHelper` per market; refused off 4663 |
| `POSITION_MANAGER`, `STATE_VIEW`, `USDG`, `WETH`, `CHAINLINK_ETH_USD`, `CHAINLINK_USDG_USD`, `MORPHO_BLUE`, `UNIVERSAL_ROUTER` | `RobinhoodChain` | external addresses; required on any other chain |

`LiquidatorHelper` still reads WETH from `RobinhoodChain`, so the script deploys it on 4663 only,
and refuses `DEPLOY_LIQUIDATOR_HELPERS=true` elsewhere until WETH is a constructor argument.

**Owned by the timelock.** The timelock has no admin: its roles and its delay change only
through its own queue. Every owner call waits the delay.

**Guarded by `GUARDIAN`.** An incident does not wait two days, so four responses belong to the
guardian as well as the owner, and the guardian's take effect at once (FAR-68):

- `pause` on either market, the only sequencer-downtime mitigation this chain allows (see
  “Trust assumptions”);
- `CollateralPolicy.freeze(poolId)`, which stops new collateral and borrows on a pool;
- `CollateralPolicy.disableToken(currency)` and `CollateralPolicy.revokeHook(hooks)`, which
  stop them on every pool of that token or behind that hook, with no freeze each (FAR-74). A
  hook that passes the bit check is the exception: revoking it stops nothing, `freeze` does.

```sh
cast send <market> "pause()" --rpc-url robinhood --private-key <guardian key>
cast send <CollateralPolicy> "freeze(bytes32)" <poolId> --rpc-url robinhood --private-key <guardian key>
```

The reverse of each is the owner's and waits the delay: `unpause`, `setFrozen(poolId, false)`,
`setTokenConfig` with `enabled = true`, `setHookAllowlist(hooks, true)`. So is what follows a
freeze: the guardian closes the pool at once, and the owner's new LT arrives through the queue.
That delay works for borrowers: lowering an LT or raising `removeHaircutBps` is visible in the
timelock's queue (`CallScheduled`) before it applies. Replacing the guardian is `setGuardian`, an
owner call on each of the three contracts. A market upgrade waits twice: the timelock's delay to
run `scheduleUpgrade`, then the market's own `TIMELOCK_DELAY` before `upgradeToAndCall` (four days
at the defaults).

**A standing `unpause`, one per market.** Only the owner can `unpause`, so without it a guardian's
pause lasts at least the delay, two days with no liquidation, and that holds for a false alarm
too. The timelock's operations do not expire, and `unpause()` on a market that is not paused
reverts and leaves the operation ready. So right after the deploy the proposer schedules one
`unpause` for each market. It is ready two days later and stays ready until a pause needs it;
the executor then ends that pause in one transaction.

```sh
# once per market after the deploy, and again after each use, under a salt not used before
TIMELOCK=0x… TARGET=<market> CALLDATA=$(cast calldata "unpause()") SALT=$(cast to-uint256 1) \
    forge script script/Timelock.s.sol --sig "schedule()" --rpc-url robinhood --broadcast --private-key …
# to end a pause: the same variables
TIMELOCK=0x… TARGET=<market> CALLDATA=$(cast calldata "unpause()") SALT=$(cast to-uint256 1) \
    forge script script/Timelock.s.sol --sig "execute()" --rpc-url robinhood --broadcast --private-key …
```

The pause that uses it up leaves the market without one for two days, so schedule the next at
once. The guardian still cannot end a pause: the standing operation is the executor's to run.

The guardian's key should be one that can be reached in minutes and is not the deployer's. See
the [pause and emergency guide](https://docs.farmenta.fun/docs/risk/pause-and-emergency) for its
powers and the cost of a mistaken pause.

**The policy needs one more step.** Its token configuration has to be written by its owner
during the run, so it is deployed owned by the deployer and handed to the timelock with
`transferOwnership`. The timelock accepts only through its queue. When the deployer is a
proposer, the run schedules `acceptOwnership()` itself, and anyone with the executor role runs
it once the delay has passed:

```sh
TIMELOCK=0x… TARGET=<CollateralPolicy> CALLDATA=$(cast calldata "acceptOwnership()") \
    forge script script/Timelock.s.sol --sig "execute()" --rpc-url robinhood --broadcast --private-key …
```

Until then the deployer still owns the policy, and can list pools directly.

Any other owner call goes the same way: `--sig "schedule()"`, wait, then `--sig "execute()"`
with the same `TARGET`, `CALLDATA` and `SALT`; `--sig "cancel()"` withdraws it. For an upgrade,
`script/Upgrade.s.sol --sig "deployReplacement()"` deploys the new implementation, and the
header of `script/Timelock.s.sol` lists the three timelock operations that install it.

## What `FarmentaMarket` does today

Custody, lending and liquidation.

- **Custody.** Positions can be deposited, deposited with a signed permit, minted straight
  into custody from the tokens themselves, withdrawn once nothing is owed, and rescued by the
  owner if one arrives unrecorded.
- **Lending.** Borrowing and repayment run on an index-based ledger that accrues interest,
  and every borrow passes the oracle price checks first. The vault counts
  `totalBorrows` less `reserves` in `totalAssets`, and `maxWithdraw`/`maxRedeem` are bounded by
  available cash.
- **Liquidation.** An underwater position can be liquidated in part or whole, and bad debt is
  taken from reserves before it reaches depositors.
- **Fee claims.** A depositor can claim a held position's fees without taking it out of custody.
  With debt outstanding, the claim passes the same oracle price checks as a borrow and must leave
  the health factor at or above 1.
- **Adding liquidity.** A borrower can add to a position in custody with a Permit2 signature,
  while its pool remains eligible. The tokens go straight to `PositionManager` and never through
  the market. The position's fees are claimed to the borrower in the same transaction, so a
  position whose fees exceed what the addition costs can still be added to; with debt outstanding
  that claim passes the same oracle price checks as a borrow and must leave the health factor at or
  above 1.
- **Removing liquidity.** A borrower can take part of a position's liquidity out without taking the
  position out of custody. The slice's principal and every fee the position holds go straight to
  the recipient, USDG first, and `min0`/`min1` bound the principal alone. What stays must still
  clear the pool's minimum position value (principal after the removal haircut, fees excluded),
  owing or not, so the whole of a position never leaves this way. With debt outstanding the
  removal passes the same oracle price checks as a borrow, and what is owed must still fit the borrow
  limit of what is left: the collateral value times the lower of max LTV and the liquidation
  threshold. A health factor of 1 is not enough here, or a loan borrowed to max LTV could be walked
  up to the threshold in two calls. A frozen pool does not stop it.

Custody is central to liquidation. `PositionManager` gates
`DECREASE_LIQUIDITY` and `BURN_POSITION` behind `onlyIfApproved(msgSender())`, so
holding the NFT is what lets the market pull liquidity during liquidation. A market that
recorded a loan but left the NFT with the borrower could not liquidate it. The subscriber
mechanism cannot substitute: an owner can always unsubscribe, and a transfer unsubscribes
automatically.

### The permit signature is not a standard one

ERC-721 has no permit. `depositCollateralWithPermit` uses Uniswap's own
`ERC721Permit_v4`, whose EIP-712 domain carries name, chainId and verifyingContract
and **no `version` field**. Wallet helpers and examples almost always add one, and
the resulting signature fails with nothing to say why. Its arguments also run
deadline-then-nonce while the signed struct hashes them the other way round. A test
signs over the four-field domain and asserts the rejection, so the trap is pinned
rather than remembered.

### Minting into custody settles through PositionManager

`mintAndDeposit` takes a borrower who holds tokens rather than a position to recorded
collateral in one transaction. The position gets no leniency for being minted by the market:
it passes the same admission checks as any deposit, and a refusal reverts everything. Two
mechanics are easy to get wrong, and `test/fork/MarketMintAndDeposit.t.sol` pins each:

- **The tokenId is read before minting.** `modifyLiquidities` returns nothing, so the id comes
  from `PositionManager.nextTokenId()`. Read afterwards, it names the next position, which
  does not exist yet.
- **The borrower's tokens never pass through the market** (FAR-45). The permit delivers each
  ERC-20 leg to PositionManager, which settles out of its own balance (`SETTLE` with
  `payerIsUser = false`) and sweeps the change back, borrow asset first. The market grants no
  approval and computes no change. Earlier implementations pulled the tokens into the market,
  where they counted toward `totalAssets` while the pool's hook ran: a hook redeeming vault
  shares mid-mint was paid 48,571 USDG for shares worth 20,000, out of the borrower's change.
  `SWEEP` hands over PositionManager's whole balance of each currency, so tokens stranded
  there go to the borrower.

The signature is a Permit2 `PermitBatchTransferFrom` with the market as spender. It lists the
pool's ERC-20 currencies in pool order: both for an ERC-20 pair, or only currency1 beside
native ETH. Native ETH is sent as `msg.value`, which must equal `amount0Max`.

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
`repay × (1 + bonus)` are properties of `FarmentaMarket`, and follow it.

CI runs the fast lane on every push and the deep lane on PRs to `main` plus nightly.

### `block.number` lies here

Robinhood Chain is an Arbitrum Orbit chain, so `block.number` reports the **L1** block, not
the L2 block — and Foundry versions disagree about whether a fork surfaces that. Never
assert on it, and never use it for timing: interest accrual and the TWAP window are defined
on `block.timestamp`. Fork tests assert they are at the pinned block by
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

The owner powers are disclosed above. Other trust assumptions:

- Only the market sits behind a proxy. `PositionValuer`, `PriceOracle`, `CollateralPolicy`
  and `InterestRateModel` are plain contracts held as immutables and changed by upgrading —
  every extra proxy doubles the storage-collision surface without adding a capability.
- The owner and the guardian can `pause`, and pausing halts liquidations too. Robinhood Chain
  publishes no Chainlink L2 Sequencer Uptime Feed, so pausing is the only sequencer-downtime
  mitigation available. Deployed by `script/Deploy.s.sol`, the owner is a
  `TimelockController`: its pause takes effect only after its delay, the guardian's at once,
  and only the owner can `unpause`, so a pause lasts at least that delay unless a standing
  `unpause` is already waiting in the queue (see “Deploying”).
- Robinhood Chain is L2BEAT **Stage 0** with 2 validators; the sequencer can filter
  transactions. "A liquidation can always be submitted" is an assumption, not a guarantee.
- **Stray ETH can be rescued by the owner.** `receive()` accepts native ETH used during
  liquidation. Liquidation forwards both payout legs in the same call, while minting,
  liquidity additions, fee claims and liquidity removals do not leave ETH stranded in the
  market. The owner can sweep ETH that arrives outside those flows with
  `rescueUnaccountedEth`. Review the [owner powers](https://docs.farmenta.fun/docs/risk/admin-powers)
  and [liquidation mechanics](https://docs.farmenta.fun/docs/liquidations/mechanics).

## License

MIT. Note that `lib/v4-core` is BUSL-1.1 until 2027-06-15 — Farmenta uses the official
PoolManager deployment and never deploys its own. Revert v4lend is BUSL-1.1 as well and is
referenced for its patterns only; no code is copied from it.
