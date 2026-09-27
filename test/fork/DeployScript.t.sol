// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {Deploy} from "../../script/Deploy.s.sol";
import {Timelock} from "../../script/Timelock.s.sol";
import {FarmentaMarket} from "../../src/FarmentaMarket.sol";
import {RobinhoodChain} from "../../src/constants/RobinhoodChain.sol";
import {ICollateralPolicy} from "../../src/interfaces/ICollateralPolicy.sol";
import {MarketUpgrade} from "../../src/libraries/MarketUpgrade.sol";
import {ForkTest} from "../base/ForkTest.sol";

/// @notice `script/Deploy.s.sol` deploys the protocol wired together and owned by a timelock, and
///         every owner call then waits the timelock's delay.
/// @dev The deployer is this contract: `run()` broadcasts as its `msg.sender`, and with no
///      `OWNER` set it is also the timelock's proposer and executor.
///
///      Environment variables are process-wide and tests run in parallel, so no test here sets
///      one `Deploy` reads, and only `test_timelockScriptSchedulesExecutesAndCancels` sets the
///      ones `Timelock` reads.
contract DeployScriptForkTest is ForkTest {
    Deploy internal script;
    Deploy.Deployment internal d;

    function setUp() public override {
        super.setUp();
        script = new Deploy();
        // `deploy(config())` is `run()` without the manifest, which a test must not write.
        d = script.deploy(script.config());
    }

    function test_deploysBothMarketsWiredToOneStack() public view {
        assertEq(uint8(d.blueChip.tier()), uint8(ICollateralPolicy.Tier.BLUE_CHIP), "blue-chip tier");
        assertEq(uint8(d.meme.tier()), uint8(ICollateralPolicy.Tier.MEME), "meme tier");
        assertEq(d.blueChip.symbol(), "fUSDG-BC");
        assertEq(d.meme.symbol(), "fUSDG-MEME");
        assertEq(d.blueChip.asset(), RobinhoodChain.USDG);
        assertEq(_implementation(d.blueChip), address(d.implementation), "blue-chip implementation");
        assertEq(_implementation(d.meme), address(d.implementation), "meme implementation");
        assertEq(address(d.blueChip.policy()), address(d.policy));
        assertEq(address(d.oracle.policy()), address(d.policy));
        assertEq(address(d.oracle.recorder()), address(d.recorder));
        assertEq(address(d.valuer.oracle()), address(d.oracle));
        assertEq(address(d.blueChipLens.market()), address(d.blueChip));
        assertEq(address(d.memeLens.market()), address(d.meme));
        assertEq(address(d.blueChipLiquidator.market()), address(d.blueChip));
        assertEq(address(d.memeLiquidator.market()), address(d.meme));

        (bool enabled, ICollateralPolicy.Tier tier, uint8 decimals, address feed) =
            d.policy.tokenConfig(_currency(RobinhoodChain.WETH));
        assertTrue(enabled);
        assertEq(uint8(tier), uint8(ICollateralPolicy.Tier.BLUE_CHIP));
        assertEq(decimals, 18);
        assertEq(feed, RobinhoodChain.CHAINLINK_ETH_USD);
        (,,, feed) = d.policy.tokenConfig(_currency(RobinhoodChain.USDG));
        assertEq(feed, RobinhoodChain.CHAINLINK_USDG_USD);
    }

    function test_timelockOwnsTheMarketsAndHasNoOtherAdmin() public view {
        TimelockController t = d.timelock;
        assertEq(d.admin, address(t));
        assertEq(d.blueChip.owner(), address(t), "blue-chip owner");
        assertEq(d.meme.owner(), address(t), "meme owner");
        assertEq(t.getMinDelay(), d.blueChip.TIMELOCK_DELAY(), "delay differs from the market's own");
        assertTrue(t.hasRole(t.PROPOSER_ROLE(), address(this)));
        assertTrue(t.hasRole(t.EXECUTOR_ROLE(), address(this)));
        assertFalse(t.hasRole(t.DEFAULT_ADMIN_ROLE(), address(this)), "the deployer kept admin");
        assertFalse(t.hasRole(t.EXECUTOR_ROLE(), address(0)), "anyone can execute");
    }

    /// @notice The policy stays the deployer's until the scheduled `acceptOwnership` executes.
    function test_policyPassesToTheTimelockOnlyAfterTheDelay() public {
        assertEq(d.policy.owner(), address(this));
        assertEq(d.policy.pendingOwner(), address(d.timelock));
        assertTrue(d.timelock.isOperationPending(d.acceptOperation), "accept was not scheduled");

        bytes memory accept = abi.encodeCall(d.policy.acceptOwnership, ());
        vm.warp(block.timestamp + d.timelock.getMinDelay() - 1);
        vm.expectRevert(_notReady(address(d.policy), accept, bytes32(0)));
        d.timelock.execute(address(d.policy), 0, accept, bytes32(0), bytes32(0));

        vm.warp(block.timestamp + 1);
        d.timelock.execute(address(d.policy), 0, accept, bytes32(0), bytes32(0));
        assertEq(d.policy.owner(), address(d.timelock));
    }

    /// @notice Pausing is an owner call too, so it waits the delay like any other.
    function test_pauseWaitsTheDelay() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        d.blueChip.pause();

        bytes memory pause = abi.encodeCall(FarmentaMarket.pause, ());
        _schedule(address(d.blueChip), pause);
        vm.expectRevert(_notReady(address(d.blueChip), pause, bytes32(0)));
        _execute(address(d.blueChip), pause);

        vm.warp(block.timestamp + d.timelock.getMinDelay());
        _execute(address(d.blueChip), pause);
        assertTrue(d.blueChip.paused());
    }

    /// @notice An upgrade crosses the timelock's queue, then the market's own, and the market's
    ///         holds on its own: both operations are queued at once, so the install is ready on
    ///         the timelock two days before the market's `eta`, and the market refuses it.
    function test_upgradeCrossesBothQueues() public {
        FarmentaMarket replacement =
            new FarmentaMarket(positionManager, d.policy, d.valuer, d.oracle, d.interestRateModel);
        uint256 delay = d.timelock.getMinDelay();
        address market = address(d.blueChip);
        bytes memory scheduleUpgrade = abi.encodeCall(FarmentaMarket.scheduleUpgrade, (address(replacement)));
        bytes memory install = abi.encodeCall(d.blueChip.upgradeToAndCall, (address(replacement), ""));
        bytes32 first = d.timelock.hashOperation(market, 0, scheduleUpgrade, bytes32(0), bytes32(0));

        d.timelock.schedule(market, 0, scheduleUpgrade, bytes32(0), bytes32(0), delay);
        d.timelock.schedule(market, 0, install, first, bytes32(0), delay);

        vm.warp(block.timestamp + delay - 1);
        vm.expectRevert(_notReady(market, scheduleUpgrade, bytes32(0)));
        _execute(market, scheduleUpgrade);

        vm.warp(block.timestamp + 1);
        _execute(market, scheduleUpgrade);
        (address pending, uint256 eta) = d.blueChip.pendingUpgrade();
        assertEq(pending, address(replacement));
        assertEq(eta, block.timestamp + d.blueChip.TIMELOCK_DELAY(), "eta");

        // Ready on the timelock, not yet on the market: the refusal is the market's.
        assertTrue(d.timelock.isOperationReady(d.timelock.hashOperation(market, 0, install, first, bytes32(0))));
        vm.expectRevert(abi.encodeWithSelector(MarketUpgrade.UpgradeNotReady.selector, address(replacement), eta));
        d.timelock.execute(market, 0, install, first, bytes32(0));

        vm.warp(eta - 1);
        vm.expectRevert(abi.encodeWithSelector(MarketUpgrade.UpgradeNotReady.selector, address(replacement), eta));
        d.timelock.execute(market, 0, install, first, bytes32(0));

        vm.warp(eta);
        d.timelock.execute(market, 0, install, first, bytes32(0));
        assertEq(_implementation(d.blueChip), address(replacement));
        assertEq(_implementation(d.meme), address(d.implementation), "the other market moved too");
    }

    /// @notice script/manifest.sh names the fields of the returned `Deployment` by position, so
    ///         the struct's order is pinned here to the list in that script.
    function test_deploymentFieldOrderMatchesTheManifest() public view {
        address[15] memory expected = [
            address(d.timelock),
            address(d.recorder),
            address(d.policy),
            address(d.oracle),
            address(d.valuer),
            address(d.interestRateModel),
            address(d.implementation),
            address(d.blueChip),
            address(d.meme),
            address(d.blueChipLens),
            address(d.memeLens),
            address(d.blueChipLiquidator),
            address(d.memeLiquidator),
            d.admin,
            address(0)
        ];
        bytes memory encoded = abi.encode(d);
        assertEq(encoded.length, 15 * 32, "Deployment gained or lost a field: update script/manifest.sh");
        for (uint256 i; i < 14; ++i) {
            bytes32 word;
            assembly ("memory-safe") {
                word := mload(add(add(encoded, 0x20), mul(i, 0x20)))
            }
            assertEq(address(uint160(uint256(word))), expected[i], "field order differs from script/manifest.sh");
        }
        bytes32 last;
        assembly ("memory-safe") {
            last := mload(add(encoded, add(0x20, mul(14, 0x20))))
        }
        assertEq(last, d.acceptOperation, "policyAcceptOperation");
    }

    /// @notice `script/Timelock.s.sol` names one operation by its variables across all three runs.
    /// @dev The script broadcasts as the default sender, so that is who holds the roles here.
    function test_timelockScriptSchedulesExecutesAndCancels() public {
        address[] memory roles = new address[](1);
        roles[0] = DEFAULT_SENDER;
        TimelockController t = new TimelockController(1 days, roles, roles, address(0));
        FarmentaMarket target = d.meme;
        _transferThroughQueue(target, address(t));

        Timelock timelockScript = new Timelock();
        vm.setEnv("TIMELOCK", vm.toString(address(t)));
        vm.setEnv("TARGET", vm.toString(address(target)));
        vm.setEnv("CALLDATA", vm.toString(abi.encodeCall(FarmentaMarket.pause, ())));

        (bytes32 id, uint256 readyAt) = timelockScript.schedule();
        assertEq(readyAt, block.timestamp + 1 days);
        vm.expectRevert(abi.encodeWithSelector(Timelock.NotReady.selector, id, readyAt, block.timestamp));
        timelockScript.execute();

        vm.warp(readyAt);
        timelockScript.execute();
        assertTrue(target.paused());

        vm.setEnv("CALLDATA", vm.toString(abi.encodeCall(FarmentaMarket.unpause, ())));
        (id,) = timelockScript.schedule();
        timelockScript.cancel();
        assertFalse(t.isOperation(id), "the cancelled operation is still queued");
        vm.expectRevert(abi.encodeWithSelector(Timelock.NotPending.selector, id));
        timelockScript.execute();
    }

    /// @notice `DEPLOY_TIMELOCK=false`: `OWNER` owns the markets from `initialize`, and the policy
    ///         once it accepts.
    function test_withoutTimelockOwnerOwnsEverything() public {
        address owner = makeAddr("owner");
        Deploy.Config memory c = script.config();
        c.timelock = false;
        c.owner = owner;
        Deploy.Deployment memory e = script.deploy(c);

        assertEq(address(e.timelock), address(0), "a timelock was deployed");
        assertEq(e.admin, owner);
        assertEq(e.blueChip.owner(), owner);
        assertEq(e.meme.owner(), owner);
        assertEq(e.policy.pendingOwner(), owner);
        vm.prank(owner);
        e.policy.acceptOwnership();
        assertEq(e.policy.owner(), owner);
    }

    /// @notice A proposer other than the deployer: nothing is scheduled for it, and the policy
    ///         moves once the proposer schedules and executes the accept.
    function test_proposerOtherThanTheDeployerSchedulesTheAccept() public {
        address proposer = makeAddr("proposer");
        Deploy.Config memory c = script.config();
        c.timelockProposer = proposer;
        c.timelockExecutor = proposer;
        Deploy.Deployment memory e = script.deploy(c);

        assertEq(e.acceptOperation, bytes32(0), "the deployer scheduled without the role");
        assertEq(e.policy.pendingOwner(), address(e.timelock));

        bytes memory accept = abi.encodeCall(e.policy.acceptOwnership, ());
        uint256 delay = e.timelock.getMinDelay();
        vm.prank(proposer);
        e.timelock.schedule(address(e.policy), 0, accept, bytes32(0), bytes32(0), delay);
        vm.warp(block.timestamp + delay);
        vm.prank(proposer);
        e.timelock.execute(address(e.policy), 0, accept, bytes32(0), bytes32(0));
        assertEq(e.policy.owner(), address(e.timelock));
    }

    function test_RevertWhenTheDelayIsZero() public {
        Deploy.Config memory c = script.config();
        c.timelockMinDelay = 0;
        vm.expectRevert(Deploy.ZeroTimelockDelay.selector);
        script.deploy(c);
    }

    function test_RevertWhenTheExecutorIsAddressZero() public {
        Deploy.Config memory c = script.config();
        c.timelockExecutor = address(0);
        vm.expectRevert(abi.encodeWithSelector(Deploy.ZeroAddress.selector, "TIMELOCK_EXECUTOR"));
        script.deploy(c);
    }

    function test_RevertWhenADependencyHasNoCode() public {
        Deploy.Config memory c = script.config();
        c.ethUsdFeed = makeAddr("not a feed");
        vm.expectRevert(abi.encodeWithSelector(Deploy.NoCode.selector, "CHAINLINK_ETH_USD", c.ethUsdFeed));
        script.deploy(c);
    }

    /// @notice `LiquidatorHelper` unwraps to Robinhood's WETH, so no other chain may get one.
    function test_RevertWhenALiquidatorHelperIsDeployedOffRobinhood() public {
        Deploy.Config memory c = script.config();
        vm.chainId(1);
        vm.expectRevert(abi.encodeWithSelector(Deploy.LiquidatorHelperNeedsRobinhood.selector, uint256(1)));
        script.deploy(c);

        c.liquidatorHelpers = false;
        Deploy.Deployment memory e = script.deploy(c);
        assertEq(address(e.blueChipLiquidator), address(0));
    }

    /// @dev Moves `market` from the deployed timelock to `newOwner`, through the deployed queue.
    function _transferThroughQueue(
        FarmentaMarket market,
        address newOwner
    ) private {
        bytes memory transfer = abi.encodeCall(market.transferOwnership, (newOwner));
        _schedule(address(market), transfer);
        vm.warp(block.timestamp + d.timelock.getMinDelay());
        _execute(address(market), transfer);
        vm.prank(newOwner);
        market.acceptOwnership();
    }

    function _schedule(
        address target,
        bytes memory data
    ) private {
        d.timelock.schedule(target, 0, data, bytes32(0), bytes32(0), d.timelock.getMinDelay());
    }

    function _execute(
        address target,
        bytes memory data
    ) private {
        d.timelock.execute(target, 0, data, bytes32(0), bytes32(0));
    }

    /// @dev What the timelock reverts with when an operation is queued but its delay has not passed.
    function _notReady(
        address target,
        bytes memory data,
        bytes32 predecessor
    ) private view returns (bytes memory) {
        return abi.encodeWithSelector(
            TimelockController.TimelockUnexpectedOperationState.selector,
            d.timelock.hashOperation(target, 0, data, predecessor, bytes32(0)),
            bytes32(1 << uint8(TimelockController.OperationState.Ready))
        );
    }

    function _implementation(
        FarmentaMarket market
    ) private view returns (address) {
        return address(uint160(uint256(vm.load(address(market), ERC1967Utils.IMPLEMENTATION_SLOT))));
    }

    function _currency(
        address token
    ) private pure returns (Currency) {
        return Currency.wrap(token);
    }
}
