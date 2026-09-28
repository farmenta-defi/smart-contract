// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";

import {FarmentaMarket} from "../../src/FarmentaMarket.sol";
import {InterestRateModel} from "../../src/InterestRateModel.sol";
import {RobinhoodChain} from "../../src/constants/RobinhoodChain.sol";
import {ICollateralPolicy} from "../../src/interfaces/ICollateralPolicy.sol";
import {IInterestRateModel} from "../../src/interfaces/IInterestRateModel.sol";
import {IPositionValuer} from "../../src/interfaces/IPositionValuer.sol";
import {IPriceOracle} from "../../src/interfaces/IPriceOracle.sol";
import {MarketLedger} from "../../src/libraries/MarketLedger.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// @notice Pins the market's ERC-7201 layout slot by slot, the upgrade queue and the guardian
///         included (ARCHITECTURE §4.1, §15 no. 10, FAR-21, FAR-68). No network.
/// @dev Slots are written and read raw, and compared with what the market's own getters return.
///      A field that moved would be read by its getter from a slot this file did not write.
contract StorageLayoutTest is Test {
    uint256 internal constant ROOT = uint256(MarketLedger.LOCATION);

    /// @dev `MarketLedger.Layout`, one constant per slot, in declaration order.
    uint256 internal constant TIER = ROOT;
    uint256 internal constant LOANS = ROOT + 1;
    uint256 internal constant POOL_DEBT_SHARES = ROOT + 2;
    uint256 internal constant TOTAL_BORROW_SHARES = ROOT + 3;
    uint256 internal constant TOTAL_BORROWS = ROOT + 4;
    uint256 internal constant BORROW_INDEX = ROOT + 5;
    uint256 internal constant LAST_ACCRUAL = ROOT + 6;
    uint256 internal constant RESERVES = ROOT + 7;
    uint256 internal constant RESERVE_BPS = ROOT + 8;
    uint256 internal constant TOTAL_RESERVES_WITHDRAWN = ROOT + 9;
    uint256 internal constant UPGRADE_QUEUE = ROOT + 10;
    uint256 internal constant UPGRADE_CODEHASH = ROOT + 11;
    uint256 internal constant GUARDIAN = ROOT + 12;

    /// @dev Every slot of the namespace that holds a value directly, the queue's two and the
    ///      guardian's left out.
    uint256 internal constant LEDGER_SLOTS = 10;

    uint256 internal constant TOKEN_ID = 77;
    PoolId internal constant POOL_ID = PoolId.wrap(bytes32(uint256(0xF001)));

    address internal owner = address(0xA11CE);
    address internal borrower = address(0xB0110);
    address internal guardian = address(0x6A4D);

    address internal interestRateModel;
    MockERC20 internal usdg;
    FarmentaMarket internal implementation;
    FarmentaMarket internal market;

    function setUp() public {
        usdg = new MockERC20("Paxos USDG", "USDG", RobinhoodChain.USDG_DECIMALS);
        interestRateModel = address(new InterestRateModel());
        implementation = _deployImplementation();
        market = FarmentaMarket(
            payable(address(
                    new ERC1967Proxy(
                        address(implementation),
                        abi.encodeCall(
                            FarmentaMarket.initialize,
                            (IERC20(address(usdg)), "Farmenta USDG Meme", "fUSDG-M", ICollateralPolicy.Tier.MEME, owner)
                        )
                    )
                ))
        );
    }

    function test_theNamespaceIsTheErc7201Location() public pure {
        bytes32 expected =
            keccak256(abi.encode(uint256(keccak256("farmenta.storage.Market")) - 1)) & ~bytes32(uint256(0xff));
        assertEq(MarketLedger.LOCATION, expected, "namespace root");
    }

    /// @notice `initialize` writes the slots the layout says it writes.
    function test_initializeWritesTheSlotsTheLayoutNames() public view {
        assertEq(_load(TIER), uint256(ICollateralPolicy.Tier.MEME), "tier slot");
        assertEq(_load(BORROW_INDEX), 1e18, "borrowIndex slot");
        assertEq(_load(LAST_ACCRUAL), block.timestamp, "lastAccrual slot");
        assertEq(_load(RESERVE_BPS), uint256(2500) | uint256(250) << 16, "reserve factor and floor slot");
        assertEq(_load(UPGRADE_QUEUE), 0, "a fresh market has a schedule");
        assertEq(_load(UPGRADE_CODEHASH), 0, "a fresh market holds a code hash");
        assertEq(_load(GUARDIAN), 0, "a fresh market has a guardian");
    }

    /// @notice Every ledger field is read from the slot it has always had.
    function test_everyLedgerFieldKeepsItsSlot() public {
        _fillLedger();

        assertEq(uint8(market.tier()), uint8(ICollateralPolicy.Tier.BLUE_CHIP), "tier");
        assertEq(market.totalBorrowShares(), 3e6, "totalBorrowShares");
        assertEq(market.totalBorrows(), 4e6, "totalBorrows");
        assertEq(market.borrowIndex(), 2e18, "borrowIndex");
        assertEq(market.lastAccrual(), 6, "lastAccrual");
        assertEq(market.reserves(), 7e6, "reserves");
        assertEq(market.reserveFloorBps(), 808, "reserveFloorBps");
        assertEq(market.totalReservesWithdrawn(), 9e6, "totalReservesWithdrawn");

        MarketLedger.Loan memory loan = market.loanOf(TOKEN_ID);
        assertEq(loan.owner, borrower, "loan owner");
        assertEq(uint8(loan.tier), uint8(ICollateralPolicy.Tier.MEME), "loan tier");
        assertEq(loan.debtShares, 11e6, "loan debtShares");
        assertEq(PoolId.unwrap(loan.poolKeyId), PoolId.unwrap(POOL_ID), "loan poolKeyId");

        // Shares are read back as debt at the index above: 13e6 shares at 2e18.
        assertEq(market.debtOf(TOKEN_ID), 22e6, "debtOf");
        assertEq(market.poolDebt(POOL_ID), 26e6, "poolDebt");

        (address pending, uint256 eta) = market.pendingUpgrade();
        assertEq(pending, address(0xABCD), "pendingImplementation");
        assertEq(eta, 1234, "upgradeEta");
        assertEq(market.pendingUpgradeCodehash(), bytes32(uint256(0xC0DE5)), "pendingCodehash");
        assertEq(market.guardian(), guardian, "guardian");
    }

    /// @notice The queue sits in the two slots after the last field: address then eta packed in
    ///         the first, the hash of the scheduled code in the second.
    function test_theUpgradeQueueTakesTheSlotAfterTheLastField() public {
        address next = address(_deployImplementation());

        vm.prank(owner);
        market.scheduleUpgrade(next);

        uint256 eta = block.timestamp + market.TIMELOCK_DELAY();
        assertEq(_load(UPGRADE_QUEUE), uint256(uint160(next)) | eta << 160, "queue slot");
        assertEq(_load(UPGRADE_CODEHASH), uint256(next.codehash), "code hash slot");
    }

    /// @notice The guardian sits in the slot after the queue's two, alone in it.
    function test_theGuardianTakesTheSlotAfterTheQueue() public {
        vm.prank(owner);
        market.setGuardian(guardian);

        assertEq(_load(GUARDIAN), uint256(uint160(guardian)), "guardian slot");
    }

    /// @notice Naming and removing the guardian write its slot and no other.
    function test_theGuardianWritesNoSlotButItsOwn() public {
        vm.record();
        vm.prank(owner);
        market.setGuardian(guardian);
        _assertOnlyWritten(GUARDIAN, GUARDIAN, "setGuardian");

        vm.record();
        vm.prank(owner);
        market.setGuardian(address(0));
        _assertOnlyWritten(GUARDIAN, GUARDIAN, "setGuardian(0)");
        assertEq(_load(GUARDIAN), 0, "removing the guardian left its slot set");
    }

    /// @notice Scheduling and cancelling write the queue's two slots and no other.
    function test_theQueueWritesNoSlotButItsOwn() public {
        address next = address(_deployImplementation());

        vm.record();
        vm.prank(owner);
        market.scheduleUpgrade(next);
        _assertOnlyWritten(UPGRADE_QUEUE, UPGRADE_CODEHASH, "scheduleUpgrade");

        vm.record();
        vm.prank(owner);
        market.cancelUpgrade();
        _assertOnlyWritten(UPGRADE_QUEUE, UPGRADE_CODEHASH, "cancelUpgrade");
        assertEq(_load(UPGRADE_QUEUE), 0, "cancelling left the queue slot set");
        assertEq(_load(UPGRADE_CODEHASH), 0, "cancelling left the code hash set");
    }

    /// @notice An upgrade through the queue leaves every ledger slot as it found it, and the
    ///         queue empty.
    function test_anUpgradeThroughTheQueueKeepsTheLedger() public {
        _fillLedger();
        vm.store(address(market), bytes32(UPGRADE_QUEUE), bytes32(0));
        vm.store(address(market), bytes32(UPGRADE_CODEHASH), bytes32(0));
        address next = address(_deployImplementation());

        vm.prank(owner);
        market.scheduleUpgrade(next);

        uint256 guardianSlot = _load(GUARDIAN);
        uint256[] memory ledger = _ledgerSlots();
        bytes32 loanRoot = _loanRoot(TOKEN_ID);
        uint256[3] memory loan = [_load(uint256(loanRoot)), _load(uint256(loanRoot) + 1), _load(uint256(loanRoot) + 2)];
        uint256 poolShares = _load(uint256(keccak256(abi.encode(POOL_ID, POOL_DEBT_SHARES))));

        vm.warp(block.timestamp + market.TIMELOCK_DELAY());
        vm.prank(owner);
        market.upgradeToAndCall(next, "");

        uint256[] memory ledgerAfter = _ledgerSlots();
        for (uint256 i = 0; i < LEDGER_SLOTS; ++i) {
            assertEq(ledgerAfter[i], ledger[i], string.concat("ledger slot moved: ", vm.toString(i)));
        }
        assertEq(_load(uint256(loanRoot)), loan[0], "loan owner and tier");
        assertEq(_load(uint256(loanRoot) + 1), loan[1], "loan debtShares");
        assertEq(_load(uint256(loanRoot) + 2), loan[2], "loan poolKeyId");
        assertEq(_load(uint256(keccak256(abi.encode(POOL_ID, POOL_DEBT_SHARES)))), poolShares, "poolDebtShares");
        assertEq(_load(UPGRADE_QUEUE), 0, "the upgrade left its schedule behind");
        assertEq(_load(UPGRADE_CODEHASH), 0, "the upgrade left its code hash behind");
        assertEq(_load(GUARDIAN), guardianSlot, "guardian");
        assertEq(market.owner(), owner, "owner");
        assertEq(market.asset(), address(usdg), "vault asset");
    }

    /* --------------------------------- helpers -------------------------------- */

    /// @dev One distinct value per slot, so a getter reading a neighbour cannot pass.
    function _fillLedger() private {
        _store(TIER, uint256(ICollateralPolicy.Tier.BLUE_CHIP));
        _store(TOTAL_BORROW_SHARES, 3e6);
        _store(TOTAL_BORROWS, 4e6);
        _store(BORROW_INDEX, 2e18);
        _store(LAST_ACCRUAL, 6);
        _store(RESERVES, 7e6);
        _store(RESERVE_BPS, uint256(707) | uint256(808) << 16);
        _store(TOTAL_RESERVES_WITHDRAWN, 9e6);
        _store(UPGRADE_QUEUE, uint256(uint160(address(0xABCD))) | uint256(1234) << 160);
        _store(UPGRADE_CODEHASH, 0xC0DE5);
        _store(GUARDIAN, uint256(uint160(guardian)));

        uint256 loanRoot = uint256(_loanRoot(TOKEN_ID));
        _store(loanRoot, uint256(uint160(borrower)) | uint256(ICollateralPolicy.Tier.MEME) << 160);
        _store(loanRoot + 1, 11e6);
        _store(loanRoot + 2, uint256(PoolId.unwrap(POOL_ID)));
        _store(uint256(keccak256(abi.encode(POOL_ID, POOL_DEBT_SHARES))), 13e6);
    }

    /// @dev Every write since `vm.record()` landed in `first` or `second`.
    function _assertOnlyWritten(
        uint256 first,
        uint256 second,
        string memory action
    ) private view {
        (, bytes32[] memory writes) = vm.accesses(address(market));
        assertGt(writes.length, 0, string.concat(action, " wrote nothing"));
        for (uint256 i = 0; i < writes.length; ++i) {
            uint256 slot = uint256(writes[i]);
            assertTrue(slot == first || slot == second, string.concat(action, " wrote outside its own slots"));
        }
    }

    function _ledgerSlots() private view returns (uint256[] memory slots) {
        slots = new uint256[](LEDGER_SLOTS);
        for (uint256 i = 0; i < LEDGER_SLOTS; ++i) {
            slots[i] = _load(ROOT + i);
        }
    }

    function _loanRoot(
        uint256 tokenId
    ) private pure returns (bytes32) {
        return keccak256(abi.encode(tokenId, LOANS));
    }

    function _load(
        uint256 slot
    ) private view returns (uint256) {
        return uint256(vm.load(address(market), bytes32(slot)));
    }

    function _store(
        uint256 slot,
        uint256 value
    ) private {
        vm.store(address(market), bytes32(slot), bytes32(value));
    }

    function _deployImplementation() private returns (FarmentaMarket) {
        return new FarmentaMarket(
            IPositionManager(payable(address(0xB0B))),
            ICollateralPolicy(address(0xC0DE)),
            IPositionValuer(address(0xDEAD)),
            IPriceOracle(address(0x0A11CE)),
            IInterestRateModel(interestRateModel)
        );
    }
}
