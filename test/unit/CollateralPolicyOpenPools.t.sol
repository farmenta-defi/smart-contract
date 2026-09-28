// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {CollateralPolicy} from "../../src/CollateralPolicy.sol";
import {RobinhoodChain} from "../../src/constants/RobinhoodChain.sol";
import {ICollateralPolicy} from "../../src/interfaces/ICollateralPolicy.sol";
import {TierPresets} from "../../src/libraries/TierPresets.sol";

/// @notice What `acceptsNewPositions` answers once a listed pool's token is switched off
///         (ARCHITECTURE §6.5, FAR-74). No network.
/// @dev `borrow` asks this function and nothing else of the policy's gates, so what it answers
///      is whether a loan can still be drawn against collateral the market already holds.
contract CollateralPolicyOpenPoolsTest is Test {
    Currency internal usdg = Currency.wrap(RobinhoodChain.USDG);
    Currency internal weth = Currency.wrap(RobinhoodChain.WETH);
    /// @dev Sorts above USDG, so the meme pair has the quote as its first currency.
    Currency internal memeToken = Currency.wrap(address(0xBEeFbeefbEefbeEFbeEfbEEfBEeFbeEfBeEfBeef));

    address internal owner = address(0xA11CE);
    address internal guardian = address(0x6A4D);

    CollateralPolicy internal policy;

    function setUp() public {
        policy = new CollateralPolicy(usdg, owner);

        vm.startPrank(owner);
        policy.setGuardian(guardian);
        policy.setTokenConfig(usdg, true, ICollateralPolicy.Tier.BLUE_CHIP, 6, address(1));
        policy.setTokenConfig(weth, true, ICollateralPolicy.Tier.BLUE_CHIP, 18, address(2));
        policy.setTokenConfig(memeToken, true, ICollateralPolicy.Tier.MEME, 18, address(0));
        vm.stopPrank();
    }

    /* --------------------------------- tokens --------------------------------- */

    /// @notice The owner's switch closes the pool without a freeze.
    function test_aPoolOfATokenTheOwnerDisabledTakesNothingNew() public {
        PoolId poolId = _list(_wethKey(200)).toId();
        assertTrue(policy.acceptsNewPositions(poolId), "a listed pool is closed");

        _setEnabled(weth, false);

        assertFalse(policy.acceptsNewPositions(poolId), "the pool still lends against a disabled token");
        assertFalse(policy.listingOf(poolId).frozen, "the pool was frozen on the way");
    }

    /// @notice The guardian's `disableToken` does the same, at once.
    function test_aPoolOfATokenTheGuardianDisabledTakesNothingNew() public {
        PoolId poolId = _list(_wethKey(200)).toId();

        vm.prank(guardian);
        policy.disableToken(weth);

        assertFalse(policy.acceptsNewPositions(poolId), "the pool still lends against a disabled token");
        assertFalse(policy.listingOf(poolId).frozen, "the pool was frozen on the way");
    }

    /// @notice Either token closes the pool, the quote included.
    function test_disablingTheQuoteClosesThePool() public {
        PoolId poolId = _list(_wethKey(200)).toId();

        vm.prank(guardian);
        policy.disableToken(usdg);

        assertFalse(policy.acceptsNewPositions(poolId), "the pool still lends with its quote disabled");
    }

    /// @notice The token is read from whichever side of the key it sits on.
    function test_aDisabledTokenClosesAPoolThatHoldsItAsCurrencyOne() public {
        PoolId poolId = _list(_memeKey()).toId();

        vm.prank(guardian);
        policy.disableToken(memeToken);

        assertFalse(policy.acceptsNewPositions(poolId), "the pool still lends against a disabled token");
    }

    /// @notice One call reaches every pool of the token, and no other pool.
    function test_aDisabledTokenClosesEveryPoolThatHoldsItAndNoOther() public {
        PoolId first = _list(_wethKey(200)).toId();
        PoolId second = _list(_wethKey(500)).toId();
        PoolId meme = _list(_memeKey()).toId();

        vm.prank(guardian);
        policy.disableToken(weth);

        assertFalse(policy.acceptsNewPositions(first), "the first pool of the token stayed open");
        assertFalse(policy.acceptsNewPositions(second), "the second pool of the token stayed open");
        assertTrue(policy.acceptsNewPositions(meme), "a pool without the token was closed");
    }

    /// @notice Enabling the token again reopens the pool on the terms it was listed with.
    function test_enablingTheTokenAgainReopensThePoolWithoutListingItAgain() public {
        PoolId poolId = _list(_wethKey(200)).toId();
        bytes32 listed = keccak256(abi.encode(policy.listingOf(poolId)));
        vm.prank(guardian);
        policy.disableToken(weth);

        _setEnabled(weth, true);

        assertTrue(policy.acceptsNewPositions(poolId), "the pool stayed closed");
        assertEq(keccak256(abi.encode(policy.listingOf(poolId))), listed, "the listing changed");
    }

    /// @notice A freeze is its own switch: enabling the token does not lift it.
    function test_aFrozenPoolStaysClosedWhenItsTokenIsEnabledAgain() public {
        PoolId poolId = _list(_wethKey(200)).toId();
        vm.startPrank(guardian);
        policy.freeze(poolId);
        policy.disableToken(weth);
        vm.stopPrank();

        _setEnabled(weth, true);

        assertFalse(policy.acceptsNewPositions(poolId), "enabling a token reopened a frozen pool");
    }

    /// @notice A pool nobody listed has no tokens on record and stays closed.
    function test_anUnlistedPoolStaysClosedWhateverItsTokensAre() public view {
        assertFalse(policy.acceptsNewPositions(_wethKey(200).toId()), "an unlisted pool is open");
    }

    /// @notice Loans that exist are judged by the same terms as before (§6.5, Delisting).
    function test_disablingATokenLeavesTheTermsReadableAndUnchanged() public {
        PoolId poolId = _list(_wethKey(200)).toId();
        bytes32 terms = keccak256(abi.encode(policy.termsOf(poolId)));
        uint16 lt = policy.effectiveLt(poolId);

        vm.prank(guardian);
        policy.disableToken(weth);

        assertEq(keccak256(abi.encode(policy.termsOf(poolId))), terms, "the terms changed");
        assertEq(policy.effectiveLt(poolId), lt, "the threshold moved");
    }

    /// @notice The reason a closed pool gives is `checkPool`'s to tell: the view only answers.
    function test_RevertWhenCheckingAPoolClosedByItsToken() public {
        PoolKey memory key = _list(_wethKey(200));

        vm.prank(guardian);
        policy.disableToken(weth);

        assertFalse(policy.acceptsNewPositions(key.toId()), "the view and the gate disagree");
        vm.expectRevert(abi.encodeWithSelector(CollateralPolicy.TokenNotEnabled.selector, weth));
        policy.checkPool(key, ICollateralPolicy.Tier.BLUE_CHIP);
    }

    /* ---------------------------------- fuzz ---------------------------------- */

    /// @notice Open means listed, not frozen, and both tokens enabled, in any combination.
    function testFuzz_aPoolIsOpenOnlyWithBothTokensEnabledAndNoFreeze(
        bool baseEnabled,
        bool quoteEnabled,
        bool frozen
    ) public {
        PoolId poolId = _list(_wethKey(200)).toId();

        _setEnabled(weth, baseEnabled);
        _setEnabled(usdg, quoteEnabled);
        vm.prank(owner);
        policy.setFrozen(poolId, frozen);

        assertEq(policy.acceptsNewPositions(poolId), baseEnabled && quoteEnabled && !frozen, "open");
    }

    /* --------------------------------- helpers -------------------------------- */

    /// @dev The owner's switch, with the tier, decimals and feed the token already has.
    function _setEnabled(
        Currency currency,
        bool enabled
    ) internal {
        (, ICollateralPolicy.Tier tier, uint8 decimals, address priceFeed) = policy.tokenConfig(currency);
        vm.prank(owner);
        policy.setTokenConfig(currency, enabled, tier, decimals, priceFeed);
    }

    function _wethKey(
        uint24 fee
    ) internal view returns (PoolKey memory) {
        return PoolKey({currency0: weth, currency1: usdg, fee: fee, tickSpacing: 4, hooks: IHooks(address(0))});
    }

    function _memeKey() internal view returns (PoolKey memory) {
        return PoolKey({currency0: usdg, currency1: memeToken, fee: 3000, tickSpacing: 60, hooks: IHooks(address(0))});
    }

    function _list(
        PoolKey memory key
    ) internal returns (PoolKey memory) {
        (, ICollateralPolicy.Tier t0,,) = policy.tokenConfig(key.currency0);
        (, ICollateralPolicy.Tier t1,,) = policy.tokenConfig(key.currency1);
        TierPresets.Preset memory preset = TierPresets.forTier(t0 > t1 ? t0 : t1);

        vm.prank(owner);
        policy.list(
            key,
            CollateralPolicy.ListingParams({
                maxLtvBps: preset.maxLtvBps,
                ltBps: preset.ltBps,
                liquidatorBonusBps: preset.minLiquidatorBonusBps,
                removeHaircutBps: 0,
                debtCapUsdg: preset.maxDebtCapUsdg,
                minPositionUsd: preset.minPositionUsd
            })
        );
        return key;
    }
}
