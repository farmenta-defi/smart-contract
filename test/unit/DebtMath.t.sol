// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {DebtMath} from "../../src/libraries/DebtMath.sol";
import {Test} from "forge-std/Test.sol";

contract DebtMathTest is Test {
    function test_borrowSharesRoundUpAndRepaySharesRoundDown() public pure {
        assertEq(DebtMath.sharesForBorrow(1, 3e18), 1);
        assertEq(DebtMath.sharesForRepay(1, 3e18), 0);
    }

    function test_accrueMatchesIndexedDebt() public pure {
        (uint256 index, uint256 borrows, uint256 interest) = DebtMath.accrue(1e18, 100e6, 100e6, 1e15, 10);
        assertEq(index, 1.01e18);
        assertEq(borrows, 101e6);
        assertEq(interest, 1e6);
    }

    function test_healthFactorUsesWadScaleAndUnlimitedZeroDebt() public pure {
        assertEq(DebtMath.healthFactor(1000e18, 7500, 650e18), 1.153846153846153846e18);
        assertEq(DebtMath.healthFactor(1000e18, 7500, 0), type(uint256).max);
    }

    function test_usdgConversionsRespectSixDecimals() public pure {
        assertEq(DebtMath.debtUsd(650e6, 98e16, 6), 637e18);
        assertEq(DebtMath.usdToDebt(637e18, 98e16, 6), 650e6);
    }

    /// @notice §6.2's `collateralValue`, to the unit. `MarketDebt`, `MarketLens` and `MarketLiquidation`
    ///         all call this one function, so comparing them with each other cannot catch a change to it
    ///         (review of PR #18).
    function test_collateralValueCountsFeesUpToATenthOfPrincipal() public pure {
        assertEq(DebtMath.collateralValue(1000e18, 50e18, 0), 1050e18, "fees under the cap count in full");
        assertEq(DebtMath.collateralValue(1000e18, 100e18, 0), 1100e18, "fees at exactly a tenth count in full");
        assertEq(DebtMath.collateralValue(1000e18, 300e18, 0), 1100e18, "fees above the cap count as a tenth");
    }

    function test_collateralValueTakesTheRemovalHaircutOffEverything() public pure {
        assertEq(DebtMath.collateralValue(1000e18, 50e18, 500), 997.5e18, "5% off principal and fees");
        assertEq(DebtMath.collateralValue(1000e18, 300e18, 500), 1045e18, "5% off the capped value");
        assertEq(DebtMath.collateralValue(1000e18, 300e18, 10_000), 0, "a full haircut leaves nothing");
    }

    /// @dev Both divisions round down: a tenth of 999 is 99, and 1098 * 9999 / 10000 is 1097.
    function test_collateralValueRoundsDown() public pure {
        assertEq(DebtMath.collateralValue(999, 1000, 1), 1097);
    }
}
