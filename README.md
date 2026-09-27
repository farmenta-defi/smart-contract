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

1. **Kunci owner dapat mengambil seluruh aset, tetapi tidak lagi tanpa peringatan.**
   `FarmentaMarket` memakai UUPS; `_authorizeUpgrade` dibatasi `onlyOwner`, dengan
   `Ownable2StepUpgradeable` untuk perpindahan ownership. Owner EOA dalam desain MVP
   tetap dapat mengganti seluruh logika, termasuk mengambil semua NFT jaminan dan
   deposit USDG. Ini tetap risiko terbesar protokol.

   **Setiap upgrade melewati timelock 2 hari (FAR-21).** Owner harus memanggil
   `scheduleUpgrade(newImplementation)` lebih dulu. Saat itu event
   `UpgradeScheduled(newImplementation, eta)` terbit, dengan
   `eta = waktu penjadwalan + TIMELOCK_DELAY`, dan `pendingUpgrade()` memperlihatkan
   jadwal yang sedang menunggu. `upgradeToAndCall` ditolak sebelum `eta`, ditolak untuk
   implementasi yang tidak dijadwalkan, dan ditolak untuk implementasi yang berbeda dari
   yang dijadwalkan.

   **Jadwal kedaluwarsa 14 hari sesudah `eta`.** Sesudah `eta + TIMELOCK_GRACE`,
   `upgradeToAndCall` ditolak (`UpgradeExpired`); owner harus membatalkan jadwal itu dan
   menjadwalkan ulang, yang berarti pengumuman baru dan jeda 2 hari penuh. Jadi jadwal
   yang dibuat jauh sebelum seorang deposan masuk tidak dapat dipasang padanya.

   **Jadwal mengikat kode, bukan hanya alamat.** `scheduleUpgrade` menolak alamat yang
   belum berisi kode, menolak akun yang hanya menunjuk ke kode lain (delegasi EIP-7702,
   kode berawalan `0xEF`), dan mencatat hash kode yang ada di sana saat itu;
   `pendingUpgradeCodehash()` memperlihatkannya dan event `UpgradeCodeBound` mencatatnya.
   `upgradeToAndCall` ditolak bila kode di
   alamat itu sudah berbeda, termasuk bila kodenya dihapus lalu diganti, dan penolakan
   itu tidak menghabiskan jadwal. Jadi kode yang dipasang ber-hash sama dengan yang
   diumumkan.

   **Cara membaca jadwal yang menunggu.** Bandingkan hash kode di alamat terjadwal
   dengan `pendingUpgradeCodehash()`. Bila alamat itu kosong, atau hash-nya berbeda,
   pada saat mana pun selama jeda, perlakukan upgrade itu sebagai bermusuhan dan
   keluar: kontrak tidak dapat memaksa kode tetap terbaca selama jeda.

   Hanya satu jadwal yang menunggu pada satu waktu. `cancelUpgrade`
   instan dan menerbitkan `UpgradeCancelled`; menjadwalkan ulang memulai jeda dari nol.
   `TIMELOCK_DELAY` dan `TIMELOCK_GRACE` adalah konstanta di bytecode implementasi, bukan
   storage: satu-satunya cara mengubahnya adalah upgrade, dan upgrade itu sendiri menunggu
   2 hari.

   Yang **tidak** diberikan timelock ini:
   - Ia tidak mencabut kuasa. Sesudah jeda lewat owner dapat memasang implementasi apa
     pun. Jeda hanya memberi peminjam dan deposan waktu untuk keluar, dan itu hanya
     berguna bila penjadwalan benar-benar dipantau.
   - Ia tidak menjamin semua orang sempat keluar. `withdraw`/`redeem` dibatasi kas
     tersedia, jadi pada utilisasi tinggi sebagian deposan tidak dapat menarik
     seluruh dananya sebelum `eta`.
   - Ia hanya menjaga upgrade market. `pause` dan `unpause` tetap instan, dan itu
     disengaja: keadaan yang paling butuh `pause` adalah yang paling tidak punya waktu.
     Kuasa owner atas `CollateralPolicy` di poin 2 dan 3 juga tetap instan.
     Catatan ini tentang kontraknya. Deployment dari `script/Deploy.s.sol` menjadikan
     owner sebuah `TimelockController` (lihat “Deploying”), dan dengan owner itu semua
     panggilan owner ikut menunggu jeda timelock: `pause`, dan di `CollateralPolicy`
     pembekuan pool, penonaktifan token, pencabutan hook, dan pengetatan terms. Spec §6.5
     mengandaikan pengetatan itu seketika; peran guardian untuknya dilacak di FAR-68.
     Sebaliknya, penurunan LT dan kenaikan `removeHaircutBps` (poin 2 dan 3) juga menunggu
     jeda, jadi peminjam melihatnya di antrean timelock sebelum berlaku.
   - Data yang dijalankan `upgradeToAndCall` tidak ikut dijadwalkan. Yang diumumkan
     adalah alamat implementasi dan hash kodenya, dan data itu hanya dapat menjalankan
     kode implementasi tersebut.
   - Hash itu mengikat kode implementasi, bukan kode yang dipanggilnya. Linked library
     dan dependency (`policy`, `valuer`, `oracle`, `interestRateModel`) tertulis di
     implementasi sebagai alamat. Tiap alamat itu harus diperiksa sendiri: kontrak biasa,
     bukan proxy dan bukan akun delegasi. Kode di balik penunjuk dapat diganti sesudah
     upgrade terpasang, tanpa jadwal dan tanpa jeda.
   - Kode yang diumumkan bisa tidak terbaca selama jeda. Kode yang dibuat, dijadwalkan,
     dan dihapus dalam satu transaksi meninggalkan alamat kosong, dan kode ber-hash sama
     dapat dipasang kembali tepat saat upgrade.
   - Kode yang dibuat di transaksi pemasangan dapat menghapus dirinya di transaksi itu
     juga. Market lalu menjalankan alamat kosong, dan kode apa pun yang kemudian
     ditaruh di sana berjalan tanpa jadwal. Kontrak tidak dapat membedakannya dari kode
     yang sudah ada sebelumnya; tandanya sama, alamat terjadwal kosong selama jeda.
   - Selama 14 hari sesudah `eta`, implementasi itu dapat dipasang kapan saja dalam satu
     transaksi. Deposan yang masuk di jendela itu masuk dengan upgrade yang sudah menunggu:
     baca `pendingUpgrade()` sebelum menyetor, bukan hanya event.

   Kuasa yang tersisa ini diterima untuk MVP yang belum diaudit dan belum memiliki TVL
   nyata. Timelock adalah syarat yang §15 no. 9 tetapkan sebelum dana sungguhan; ia
   menunda kuasa itu, bukan mencabutnya, dan spesifikasi tidak menetapkan syarat lain
   yang mencabutnya (kunci admin sengaja tidak dibahas, §1).
   Sumber: `ARCHITECTURE.md` §4.1, **§15 no. 9**.

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

3. **Owner dapat menaikkan removal haircut pada pool yang dibekukan.** Haircut dapat
   dinaikkan hingga 2.000 bps melalui `updateTerms` hanya saat pool `frozen`; penurunan
   tetap dapat terjadi seketika. Pembekuan menghentikan collateral dan pinjaman baru,
   tetapi tidak menunda perubahan bagi pinjaman yang sudah ada atau likuidasinya. Karena
   itu kenaikan dapat langsung menurunkan nilai jaminan yang diakui dan membuat posisi
   yang sebelumnya sehat menjadi likuidatable; likuidator dapat menerima lebih dari bonus
   normal jika haircut yang dicatat melebihi potongan nyata hook saat removal (terukur
   118,12% dari `repay`, batas atas 131,25%; §6.5). Risiko ini diterima untuk respons
   operasional MVP dan harus diungkapkan di frontend sebelum TVL nyata. Sumber:
   `ARCHITECTURE.md` §6.5, **§15 no. 19**.

4. **Lantai reserve tidak mengikat pemegang kunci upgrade.** Aturan §7 membatasi
   penarikan rutin oleh owner lewat `withdrawReserves`: lantai dihitung dari
   `totalAssets × reserveFloorBps / 10_000` (1% blue-chip, 2,5% meme), dan hanya reserve
   di atas lantai yang boleh ditarik, sebatas kas tersedia. `reserveFloor()` dan
   `withdrawableReserves()` memperlihatkan buffer dan surplus saat ini, sedangkan
   `totalReservesWithdrawn()` mencatat total yang telah ditarik protokol. Bad debt tetap dapat
   menghabiskan reserve, termasuk bagian di bawah lantai.
   Meski sudah diterapkan, owner dapat mengganti aturan lantai melalui upgrade. Lantai
   mencegah penarikan rutin melewati batas; ia bukan jaminan terhadap pemegang kunci
   upgrade. Yang berubah sejak FAR-21: upgrade itu harus dijadwalkan dan menunggu
   timelock 2 hari di poin 1, jadi aturan lantai tidak dapat ditulis ulang tanpa
   pengumuman on-chain lebih dulu. Timelock menunda perubahan aturan, bukan membuat
   lantai kebal terhadap upgrade. Risiko yang tersisa diterima untuk MVP yang belum
   diaudit dan belum memiliki TVL nyata, dengan syarat yang sama seperti poin 1.
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
`MarketDebt`, then `MarketLiquidation` (§8 seizure), then `MarketLiquidity` (fee claims) linked
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
`TimelockController` that owns both markets and the policy. It configures USDG, WETH and native
ETH with their Chainlink feeds. It lists no pool: listings are curated one by one (spec §6.3).

```sh
# simulate against mainnet; nothing is sent
FOUNDRY_PROFILE=deploy OWNER=0x… forge script script/Deploy.s.sol --rpc-url robinhood
# broadcast
FOUNDRY_PROFILE=deploy OWNER=0x… forge script script/Deploy.s.sol --rpc-url robinhood \
    --broadcast --private-key $PRIVATE_KEY
```

After the broadcast, build the address manifest from its log:

```sh
script/manifest.sh            # broadcast/Deploy.s.sol/4663/run-latest.json -> deployments/4663.json
```

It needs `jq`. Every contract gets `{address, startBlock}`; `collateralPolicy`, `twapRecorder`
and `markets.{blueChip,meme}` are exactly what `indexer/config/deployment.ts` loads, so the file
goes to `indexer/deployments/<name>.json` unchanged, and the keeper's `KEEPER_LOG_START_BLOCK` is
`collateralPolicy.startBlock`. The blocks come from the receipts, not from the script:
`block.number` on this chain is the L1 block (spec §14). The manifest names the fields of the
returned `Deployment` by position; `test_deploymentFieldOrderMatchesTheManifest` pins that
order. It refuses a dry-run log, a failed transaction, and an address no receipt created.

Commit the mainnet manifest (`deployments/4663.json`) together with its broadcast log: it is the
record the services read addresses from (decided 27 Sep 2026, spec v1.56).

An `anvil` fork keeps chain id 4663, so a rehearsal against one leaves a
`broadcast/Deploy.s.sol/4663/` log that looks like a mainnet deploy: give `manifest.sh` another
output path, and delete that log afterwards.

The simulation stops before any transaction if an external address has no code, if a Chainlink
feed does not answer with a fresh price, or if the wiring read back differs from what was
deployed. Measured 2026-09-27 on a mainnet fork: 23 transactions and about 23 million gas (forge
prints 30 million: it adds a 30% margin), a few dollars at 0.02 gwei.

| Variable | Default on 4663 | Meaning |
|---|---|---|
| `OWNER` | the deployer | proposer and executor of the timelock; owner of everything when `DEPLOY_TIMELOCK=false`. Set it to a key other than the deployer's (a hardware key or a multisig): left at the default, the key in `.env` holds the whole timelock, and the run logs a warning |
| `DEPLOY_TIMELOCK` | `true` | `false` makes `OWNER` the direct owner |
| `TIMELOCK_MIN_DELAY` | `172800` (2 days) | the timelock's delay, in seconds; `0` is refused |
| `TIMELOCK_PROPOSER`, `TIMELOCK_EXECUTOR` | `OWNER` | the timelock's roles; neither may be `address(0)` |
| `DEPLOY_LIQUIDATOR_HELPERS` | `true` on 4663, `false` elsewhere | deploy one `LiquidatorHelper` per market; refused off 4663 |
| `POSITION_MANAGER`, `STATE_VIEW`, `USDG`, `WETH`, `CHAINLINK_ETH_USD`, `CHAINLINK_USDG_USD`, `MORPHO_BLUE`, `UNIVERSAL_ROUTER` | `RobinhoodChain` | external addresses; required on any other chain |

`LiquidatorHelper` still reads WETH from `RobinhoodChain`, so the script deploys it on 4663 only,
and refuses `DEPLOY_LIQUIDATOR_HELPERS=true` elsewhere until WETH is a constructor argument.

**Owned by the timelock.** The timelock has no admin: its roles and its delay change only
through its own queue. Every owner call waits the delay, and that includes the incident
responses:

- `pause`, the only sequencer-downtime mitigation this chain allows (see “Trust assumptions”);
- `CollateralPolicy.setFrozen(poolId, true)`, which stops new collateral and borrows on a pool;
- `setTokenConfig(token, false, …)` and `setHookAllowlist(hook, false)`;
- tightening a pool's terms or scheduling an LT ramp.

Spec §6.5 assumes tightening is immediate (freeze, then write the new LT). Under this owner a
pool being drained keeps taking new loans for the length of the delay. A guardian that may only
pause and tighten, at once, is tracked in FAR-68. The same delay works for borrowers: lowering an
LT or raising `removeHaircutBps` is visible in the timelock's queue (`CallScheduled`) before it
applies. A market upgrade waits twice: the timelock's delay to run `scheduleUpgrade`, then the
market's own `TIMELOCK_DELAY` before `upgradeToAndCall` (four days at the defaults).

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

### Minting into custody settles through PositionManager

`mintAndDeposit` takes a borrower who holds tokens rather than a position to recorded
collateral in one transaction. The position gets no leniency for being minted by the market:
it passes the same §6.1 admission as any deposit, and a refusal reverts everything. Two
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
  available (spec §5.2, §15.1). Deployed by `script/Deploy.s.sol`, the owner is a
  `TimelockController`, and a pause takes effect only after its delay.
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
