// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {RobinhoodChain} from "../../src/constants/RobinhoodChain.sol";
import {IAggregatorV3} from "../../src/interfaces/IAggregatorV3.sol";
import {ForkTest} from "../base/ForkTest.sol";

/// @notice Asserts every address in `RobinhoodChain` really is the contract it claims to be.
/// @dev This exists because of a concrete incident: on 2026-08-26 the frontend held an
///      ETH/USD feed address whose middle digits were wrong while its truncated form still
///      matched the docs, so review by eye passed. A wrong-but-plausible address is invisible
///      to humans and obvious to the chain — so let the chain check it.
///
///      Identity is established by asking each contract something only it can answer
///      (a feed's `description()`, a token's `symbol()`, a periphery contract's immutable
///      pointer back to the PoolManager), never by comparing to another hard-coded constant.
contract AddressesForkTest is ForkTest {
    function test_uniswapContractsPointAtEachOther() public view {
        // PositionManager and StateView both store the PoolManager as an immutable, so a
        // wrong PoolManager constant cannot survive this.
        assertEq(_addressCall(RobinhoodChain.POSITION_MANAGER, "poolManager()"), RobinhoodChain.POOL_MANAGER);
        assertEq(_addressCall(RobinhoodChain.STATE_VIEW, "poolManager()"), RobinhoodChain.POOL_MANAGER);
        assertEq(_addressCall(RobinhoodChain.POSITION_MANAGER, "permit2()"), RobinhoodChain.PERMIT2);
    }

    function test_chainlinkFeedsAreTheClaimedPairs() public view {
        IAggregatorV3 ethUsd = IAggregatorV3(RobinhoodChain.CHAINLINK_ETH_USD);
        assertEq(ethUsd.description(), "ETH / USD", "ETH/USD feed is not ETH/USD");
        assertEq(ethUsd.decimals(), 8, "unexpected feed decimals");

        IAggregatorV3 usdgUsd = IAggregatorV3(RobinhoodChain.CHAINLINK_USDG_USD);
        assertEq(usdgUsd.description(), "USDG / USD", "USDG/USD feed is not USDG/USD");
        assertEq(usdgUsd.decimals(), 8, "unexpected feed decimals");
    }

    function test_feedsReturnSanePrices() public view {
        (, int256 ethAnswer,, uint256 ethUpdatedAt,) = IAggregatorV3(RobinhoodChain.CHAINLINK_ETH_USD).latestRoundData();
        uint256 ethPrice = _positive(ethAnswer, "ETH");
        // 8 decimals: $100 .. $100,000. Wide on purpose — this catches a decimals or feed
        // mix-up, not a market move.
        assertGt(ethPrice, 100e8, "ETH price implausibly low");
        assertLt(ethPrice, 100_000e8, "ETH price implausibly high");
        assertLe(block.timestamp - ethUpdatedAt, 25 hours, "ETH feed stale at the pinned block");

        (, int256 usdgAnswer,, uint256 usdgUpdatedAt,) =
            IAggregatorV3(RobinhoodChain.CHAINLINK_USDG_USD).latestRoundData();
        uint256 usdgPrice = _positive(usdgAnswer, "USDG");
        // §5.2 bounds: outside [0.97, 1.03] borrowing is blocked.
        assertGe(usdgPrice, 0.97e8, "USDG below the depeg floor");
        assertLe(usdgPrice, 1.03e8, "USDG above the depeg ceiling");
        assertLe(block.timestamp - usdgUpdatedAt, 25 hours, "USDG feed stale at the pinned block");
    }

    /// @dev Chainlink answers are signed. A negative or zero answer is nonsense for a USD
    ///      price feed and must never be cast into an unsigned price, so the check and the
    ///      cast live together here rather than being spread across call sites.
    function _positive(
        int256 answer,
        string memory label
    ) internal pure returns (uint256) {
        assertGt(answer, 0, string.concat(label, ": non-positive price"));
        // Safe: the assertion above rules out the only values this cast could misread.
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint256(answer);
    }

    function test_tokensAreTheClaimedTokens() public view {
        assertEq(IERC20Metadata(RobinhoodChain.USDG).symbol(), "USDG");
        assertEq(IERC20Metadata(RobinhoodChain.USDG).decimals(), RobinhoodChain.USDG_DECIMALS);
        assertEq(IERC20Metadata(RobinhoodChain.WETH).symbol(), "WETH");
        assertEq(IERC20Metadata(RobinhoodChain.WETH).decimals(), RobinhoodChain.WETH_DECIMALS);
    }

    /// @dev Pyth exposes no cheap identity probe; at minimum it must be a contract, which
    ///      rules out a typo landing on an empty or EOA address.
    function test_pythIsAContract() public view {
        assertGt(RobinhoodChain.PYTH.code.length, 0, "Pyth has no code");
    }

    /// @dev §5.2/§15.1: Chainlink publishes no L2 Sequencer Uptime Feed on this chain, so
    ///      the constant is deliberately zero. If that ever changes, this failing test is
    ///      the reminder to revisit the pause-based mitigation.
    function test_noSequencerUptimeFeedIsExpected() public pure {
        assertEq(
            RobinhoodChain.SEQUENCER_UPTIME_FEED, address(0), "a sequencer uptime feed now exists - revisit spec 5.2"
        );
    }

    function _addressCall(
        address target,
        string memory sig
    ) internal view returns (address) {
        (bool ok, bytes memory ret) = target.staticcall(abi.encodeWithSignature(sig));
        require(ok && ret.length == 32, string.concat("call failed: ", sig));
        return abi.decode(ret, (address));
    }
}
