# Farmenta · Contracts

Solidity contracts for Farmenta — borrow USDG against Uniswap v4 LP position NFTs on
Robinhood Chain (chain id 4663).

Specification: [`farmenta-defi/docs`](https://github.com/farmenta-defi/docs) →
`ARCHITECTURE.md` v0.78. **The spec is the source of truth.** Where this repo and the spec
disagree, the spec wins and the code is wrong — except for addresses, which live in exactly
two places: spec §18 and `src/constants/RobinhoodChain.sol`, kept in sync by a test.

> **Status: pre-alpha.** Not audited, not deployed, not usable. Do not send funds anywhere
> derived from this code.

## Kekuasaan owner dan batasnya

**Belum diaudit.** MVP ini belum memiliki TVL nyata. Kuasa berikut harus dipahami
sebelum menyimpan NFT jaminan atau deposit USDG. Lending dan likuidasi belum
diimplementasikan; konsekuensinya di bawah mengikuti spesifikasi. Lihat batas
implementasi pada bagian “What `FarmentaMarket` does today”.

1. **Kunci owner dapat mengambil seluruh aset.** `FarmentaMarket` memakai UUPS;
   `_authorizeUpgrade` dibatasi `onlyOwner`, dengan `Ownable2StepUpgradeable` untuk
   perpindahan ownership. Owner EOA dalam desain MVP dapat mengganti seluruh logika,
   termasuk mengambil semua NFT jaminan dan deposit USDG, dalam satu transaksi tanpa
   peringatan. Ini risiko terbesar protokol. **Tidak ada timelock.**
   Dua langkah perpindahan ownership tidak memberi jeda pada upgrade. Ini diterima
   hanya untuk MVP tanpa TVL nyata dan belum diaudit.
   Sebelum dana sungguhan, timelock pada `_authorizeUpgrade` wajib diterapkan, dengan
   `pause` dikecualikan agar respons darurat tetap instan. Timelock memberi jeda; ia
   tidak menghapus kuasa mengganti logika. Pengungkapan ini wajib diperbarui ketika
   timelock diterapkan. Sumber: `ARCHITECTURE.md` §4.1, **§15 no. 9**.

2. **Owner dapat membuat pinjaman sehat menjadi likuidatable.** Owner dapat menurunkan
   liquidation threshold (LT) sebuah pool sedalam dan secepat apa pun, tanpa batas laju
   maupun lantai, termasuk seketika melalui `updateTerms`. Pool harus dibekukan dahulu
   jika LT turun ke atau di bawah max LTV; pembekuan itu membatasi pinjaman baru, bukan
   melindungi pinjaman yang sudah ada. Menurut spesifikasi, perubahan parameter berlaku
   **seketika ke pinjaman yang sudah ada**: LT efektif mengikuti jadwal jika memakai
   `scheduleLtRamp`, atau langsung berubah jika memakai `updateTerms`. Peminjam yang
   tidak melakukan kesalahan tetap dapat dilikuidasi dan menanggung bonus likuidator.
   Kuasa ini diterima untuk ketanggapan operasional MVP terhadap oracle rusak, perubahan
   hook, atau token ter-rug. Satu-satunya mitigasi adalah keterbacaan jadwal ramp on-chain
   oleh siapa pun; owner tidak wajib memakai ramp dan jadwal itu tidak membatasi kuasanya.
   Sebelum TVL nyata, simulasi parameter risiko wajib dilakukan dan konsekuensi ini harus
   disampaikan di frontend. Keduanya tidak mencabut kuasa owner; spesifikasi belum
   menetapkan pembatasan laju atau lantai untuk mencabutnya. Sumber: `ARCHITECTURE.md`
   §6.5, **§15 no. 11**; syarat simulasi: §15 no. 3.

3. **Lantai reserve tidak mengikat pemegang kunci upgrade.** Aturan §7 membatasi
   penarikan rutin oleh owner lewat `withdrawReserves`: lantai dihitung dari
   `totalAssets × reserveFloorBps / 10_000` (1% blue-chip, 2,5% meme), dan hanya reserve
   di atas lantai yang boleh ditarik, sebatas kas tersedia. `reserveFloor()` dan
   `withdrawableReserves()` memperlihatkan buffer dan surplus saat ini, sedangkan
   `totalReservesWithdrawn()` mencatat total yang telah ditarik protokol. Bad debt tetap dapat
   menghabiskan reserve, termasuk bagian di bawah lantai.
   Meski sudah diterapkan, owner dapat mengganti aturan lantai melalui upgrade dan
   mengambil aset dalam satu transaksi. Lantai mencegah penarikan rutin melewati batas;
   ia bukan jaminan terhadap pemegang kunci upgrade. Risiko ini diterima hanya untuk
   MVP tanpa TVL nyata, dengan syarat yang sama seperti kuasa upgrade: timelock pada
   `_authorizeUpgrade` wajib sebelum dana sungguhan, dengan `pause` tetap instan.
   Timelock menunda perubahan aturan, bukan membuat lantai kebal terhadap upgrade.
   Sumber: `ARCHITECTURE.md` §7, **§15 no. 13**.

Ketiga poin merujuk SOT
[`farmenta-defi/docs/ARCHITECTURE.md`](https://github.com/farmenta-defi/docs/blob/main/ARCHITECTURE.md)
v0.9. Penyampaian risiko di frontend adalah pekerjaan terpisah dari FAR-14.

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
  FarmentaMarket.sol             custodies position NFTs, lends against them, liquidates (spec §4.1)
  CollateralPolicy.sol           which pools may back a loan, on what terms (spec §4.5, §6)
  PriceOracle.sol                reads policy-listed Chainlink USD feeds (spec §4.3, §5.2)
  PositionValuer.sol             values a position at oracle prices (spec §4.2, §5.1)
  MarketLens.sol                 read-only risk views for one market proxy
  constants/RobinhoodChain.sol   deployed addresses (spec §18)
  interfaces/                    ICollateralPolicy, IPositionValuer, IPriceOracle, IAggregatorV3
  libraries/                     PositionAmounts, PriceMath, HookPermissions, TierPresets,
                                 MarketLedger, MarketDebt, MarketMint, MarketLiquidation, MarketLiquidity,
                                 LiquidationMath, DebtMath
test/
  base/       ForkTest (pinned-block harness), Fixtures (real pools, hooks, positions),
              PositionMinter (mints positions in the fork for shapes the chain lacks),
              MarketForkTest (a market wired to real policy and valuer, mock oracle)
  mocks/      MockPriceOracle and MockAggregatorV3: settable prices for isolated valuation
              and Chainlink checks; MockERC20 — a 6-decimal asset for the vault off-fork
  unit/       no network
  fork/       pinned-block reads against live Uniswap v4 state
  invariant/  properties asserted across arbitrary call sequences
script/
  DiscoverPositions.s.sol        finds real positions to use as fixtures
  InspectPositions.s.sol         prints everything the valuer reads, for one position
```

`MarketDebt`, `MarketMint`, `MarketLiquidation` and `MarketLiquidity` are linked delegatecall
libraries. Deploy and link them in order: `MarketDebt`, then `MarketMint` linked to
`MarketDebt`, then `MarketLiquidation` (§8 seizure), then `MarketLiquidity` (fee claims) linked
to `MarketDebt`, then the market implementation linked to all four. They
write only the market's ERC-7201 ledger namespace and preserve the market's caller, events,
and storage.
`MarketLens` is a separate read-only contract bound to one proxy, so deploy one lens for
each Blue-chip or Meme market and direct risk-view consumers to that lens.

## What `FarmentaMarket` does today

Custody, lending and liquidation.

- **Custody.** Positions can be deposited, deposited with a signed permit, minted straight
  into custody from the tokens themselves, withdrawn once nothing is owed, and rescued by the
  owner if one arrives unrecorded.
- **Lending.** Borrowing and repayment run on an index-based ledger that accrues interest
  (spec §7), and every borrow passes the §5.2 price gates first. The vault counts
  `totalBorrows` less `reserves` in `totalAssets`, and `maxWithdraw`/`maxRedeem` are bounded by
  the cash on hand (spec §4.1, §7).
- **Liquidation.** An underwater position can be liquidated in part or whole, and bad debt is
  taken from reserves before it reaches depositors (spec §8, §9).
- **Fee claims.** A depositor can claim a held position's fees without taking it out of custody.
  With debt outstanding, the claim passes the same §5.2 price gates as a borrow and must leave
  the health factor at or above 1 (spec §4.1, §5.2 v0.40).
- **Adding liquidity.** A borrower can add to a position in custody with a Permit2 signature,
  while its pool still passes §6.1. The tokens go straight to `PositionManager` and never through
  the market. The position's fees are claimed to the borrower in the same transaction, so a
  position whose fees exceed what the addition costs can still be added to; with debt outstanding
  that claim passes the same §5.2 price gates as a borrow and must leave the health factor at or
  above 1 (spec §4.1 v0.47, FAR-9).
- **Removing liquidity.** A borrower can take part of a position's liquidity out without taking the
  position out of custody. The slice's principal and every fee the position holds go straight to
  the recipient, USDG first, and `min0`/`min1` bound the principal alone. What stays must still
  clear the pool's minimum position value (principal after the removal haircut, fees excluded),
  owing or not, so the whole of a position never leaves this way. With debt outstanding the
  removal passes the same §5.2 price gates as a borrow, and what is owed must still fit the borrow
  limit of what is left: the collateral value times the lower of max LTV and the liquidation
  threshold. A health factor of 1 is not enough here, or a loan borrowed to max LTV could be walked
  up to the threshold in two calls (spec §4.1 v0.59). A frozen pool does not stop it (spec §4.1,
  §5.2, §6.1, §6.5, FAR-8).

Custody is the design rather than a detail. `PositionManager` gates
`DECREASE_LIQUIDITY` and `BURN_POSITION` behind `onlyIfApproved(msgSender())`, so
owning the NFT is precisely what lets the market pull liquidity during liquidation
(spec §8). A market that recorded the loan but left the token with the borrower
could never liquidate it. The subscriber mechanism cannot substitute: an owner can
always unsubscribe, and a transfer unsubscribes automatically (spec §10).

### The permit signature is not a standard one

ERC-721 has no permit. `depositCollateralWithPermit` uses Uniswap's own
`ERC721Permit_v4`, whose EIP-712 domain carries name, chainId and verifyingContract
and **no `version` field**. Wallet helpers and examples almost always add one, and
the resulting signature fails with nothing to say why. Its arguments also run
deadline-then-nonce while the signed struct hashes them the other way round. A test
signs over the four-field domain and asserts the rejection, so the trap is pinned
rather than remembered.

### Minting into custody settles through Permit2

`mintAndDeposit` takes a borrower who holds tokens rather than a position to recorded
collateral in one transaction. The position gets no leniency for being minted by the market:
it passes the same §6.1 admission as any deposit, and a refusal reverts everything. Three
mechanics are easy to get wrong, and `test/fork/MarketMintAndDeposit.t.sol` pins each:

- **The tokenId is read before minting.** `modifyLiquidities` returns nothing, so the id comes
  from `PositionManager.nextTokenId()`. Read afterwards, it names the next position, which
  does not exist yet.
- **Two approval layers, granted once per token.** PositionManager pays the market's debt with
  `permit2.transferFrom`, so the token approves Permit2 and Permit2 approves PositionManager,
  both for the maximum (§4.1). The standing allowance can only be drawn by the market's own
  calls, because PositionManager charges whoever called it.
- **Change comes back two ways.** `SWEEP` only moves what PositionManager holds, which is
  unspent ETH. ERC-20 change never leaves the market, so the market returns whatever it holds
  above its balance from before the mint. This is the one departure from §4.1, which credits
  `SWEEP` with both legs. The subtraction reverts if a mint ever spent lenders' USDG, and the
  vault refuses deposits that re-enter mid-mint, so none can be counted as change.

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

The owner powers are disclosed above. Other trust assumptions:

- Only the market sits behind a proxy. `PositionValuer`, `PriceOracle`, `CollateralPolicy`
  and `InterestRateModel` are plain contracts held as immutables and changed by upgrading —
  every extra proxy doubles the storage-collision surface without adding a capability.
- The owner can `pause`, and pausing halts liquidations too. Robinhood Chain publishes no
  Chainlink L2 Sequencer Uptime Feed, so pausing is the only sequencer-downtime mitigation
  available (spec §5.2, §15.1).
- Robinhood Chain is L2BEAT **Stage 0** with 2 validators; the sequencer can filter
  transactions. "A liquidation can always be submitted" is an assumption, not a guarantee.
- **ETH sent to the market cannot be recovered.** `receive()` is open because the fee,
  liquidity and liquidation payouts will arrive as native ETH, but none of those functions
  exists yet and there is no ETH rescue. Nothing today can make ETH arrive legitimately.
  Whether the owner gets one is open item spec §15 no. 12, to be answered alongside §8.

## License

MIT. Note that `lib/v4-core` is BUSL-1.1 until 2027-06-15 — Farmenta uses the official
PoolManager deployment and never deploys its own. Revert v4lend is BUSL-1.1 as well and is
referenced for its patterns only; no code is copied from it.
