// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";

import {Upgrade} from "../../script/Upgrade.s.sol";
import {FarmentaMarket} from "../../src/FarmentaMarket.sol";
import {InterestRateModel} from "../../src/InterestRateModel.sol";
import {RobinhoodChain} from "../../src/constants/RobinhoodChain.sol";
import {ICollateralPolicy} from "../../src/interfaces/ICollateralPolicy.sol";
import {IInterestRateModel} from "../../src/interfaces/IInterestRateModel.sol";
import {IPositionValuer} from "../../src/interfaces/IPositionValuer.sol";
import {IPriceOracle} from "../../src/interfaces/IPriceOracle.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// @notice `script/Upgrade.s.sol` takes an upgrade through the timelock, in two runs (FAR-21).
///         No network.
/// @dev The script broadcasts as whoever runs it, which in a test is the default sender, so
///      that is who owns the market here.
contract UpgradeScriptTest is Test {
    address internal posm = address(0xB0B);
    address internal policy = address(0xC0DE);
    address internal valuer = address(0xDEAD);
    address internal oracle = address(0x0A11CE);
    address internal interestRateModel;

    FarmentaMarket internal implementation;
    FarmentaMarket internal market;
    Upgrade internal script;

    function setUp() public {
        MockERC20 usdg = new MockERC20("Paxos USDG", "USDG", RobinhoodChain.USDG_DECIMALS);
        interestRateModel = address(new InterestRateModel());
        implementation = new FarmentaMarket(
            IPositionManager(payable(posm)),
            ICollateralPolicy(policy),
            IPositionValuer(valuer),
            IPriceOracle(oracle),
            IInterestRateModel(interestRateModel)
        );
        market = FarmentaMarket(
            payable(address(
                    new ERC1967Proxy(
                        address(implementation),
                        abi.encodeCall(
                            FarmentaMarket.initialize,
                            (
                                IERC20(address(usdg)),
                                "Farmenta USDG Blue-chip",
                                "fUSDG-BC",
                                ICollateralPolicy.Tier.BLUE_CHIP,
                                DEFAULT_SENDER
                            )
                        )
                    )
                ))
        );

        script = new Upgrade();
        vm.setEnv("PROXY", vm.toString(address(market)));
    }

    /// @notice `schedule()` deploys the replacement with the dependencies the market already has,
    ///         and queues it a full delay ahead.
    function test_scheduleDeploysTheReplacementAndQueuesIt() public {
        (address scheduled, uint256 eta) = script.schedule();

        (address pending, uint256 pendingEta) = market.pendingUpgrade();
        assertEq(pending, scheduled, "the script scheduled something other than it reports");
        assertEq(pendingEta, eta, "eta");
        assertEq(eta, block.timestamp + market.TIMELOCK_DELAY(), "the eta is not a full delay ahead");
        assertTrue(scheduled != address(implementation), "nothing new was deployed");
        assertEq(_installed(), address(implementation), "scheduling installed the upgrade");

        FarmentaMarket replacement = FarmentaMarket(payable(scheduled));
        assertEq(address(replacement.positionManager()), posm, "positionManager");
        assertEq(address(replacement.policy()), policy, "policy");
        assertEq(address(replacement.valuer()), valuer, "valuer");
        assertEq(address(replacement.oracle()), oracle, "oracle");
        assertEq(address(replacement.interestRateModel()), interestRateModel, "interestRateModel");
    }

    /// @notice `execute()` refuses to send an upgrade the market would refuse.
    function test_executeStopsBeforeTheEta() public {
        (address scheduled, uint256 eta) = script.schedule();
        vm.warp(eta - 1);

        vm.expectRevert(abi.encodeWithSelector(Upgrade.TooEarly.selector, scheduled, eta, eta - 1));
        script.execute();

        assertEq(_installed(), address(implementation), "the script upgraded ahead of the eta");
    }

    /// @notice `execute()` installs what the market has pending, and only that.
    function test_executeInstallsWhatWasScheduled() public {
        (address scheduled, uint256 eta) = script.schedule();
        vm.warp(eta);

        address installed = script.execute();

        assertEq(installed, scheduled, "the script installed something other than it scheduled");
        assertEq(_installed(), scheduled, "the market does not run the scheduled implementation");
        (address pending,) = market.pendingUpgrade();
        assertEq(pending, address(0), "the schedule outlived its upgrade");
    }

    function test_executeAndCancelStopWhenNothingIsScheduled() public {
        vm.expectRevert(abi.encodeWithSelector(Upgrade.NothingScheduled.selector, address(market)));
        script.execute();

        vm.expectRevert(abi.encodeWithSelector(Upgrade.NothingScheduled.selector, address(market)));
        script.cancel();
    }

    function test_cancelWithdrawsTheSchedule() public {
        (address scheduled, uint256 eta) = script.schedule();

        assertEq(script.cancel(), scheduled, "the script cancelled something other than it scheduled");

        (address pending, uint256 pendingEta) = market.pendingUpgrade();
        assertEq(pending, address(0), "the schedule is still there");
        assertEq(pendingEta, 0, "the eta is still there");

        vm.warp(eta);
        vm.expectRevert(abi.encodeWithSelector(Upgrade.NothingScheduled.selector, address(market)));
        script.execute();
    }

    /// @dev The ERC-1967 implementation slot: what the proxy actually runs.
    function _installed() internal view returns (address) {
        return address(
            uint160(
                uint256(vm.load(address(market), 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc))
            )
        );
    }
}
