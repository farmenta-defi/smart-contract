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
}
