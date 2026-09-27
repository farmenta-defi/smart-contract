// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title IPositionValuer
/// @notice Values a Uniswap v4 LP position at oracle prices (ARCHITECTURE §4.2, §5.1).
interface IPositionValuer {
    /// @param liquidity Position liquidity backing the principal.
    /// @param amount0 Raw currency0 the position holds at the oracle price.
    /// @param amount1 Raw currency1 the position holds at the oracle price.
    /// @param fees0 Raw currency0 of uncollected fees.
    /// @param fees1 Raw currency1 of uncollected fees.
    /// @param principalUsd USD value of amount0 + amount1, scaled 1e18.
    /// @param feesUsd USD value of fees0 + fees1, scaled 1e18. Reported **uncapped**.
    /// @param spotDeviationBps How far the pool's spot price sits from the oracle price.
    struct Valuation {
        uint128 liquidity;
        uint256 amount0;
        uint256 amount1;
        uint256 fees0;
        uint256 fees1;
        uint256 principalUsd;
        uint256 feesUsd;
        uint256 spotDeviationBps;
    }

    /// @notice The position does not exist, or was burned.
    error PositionNotFound(uint256 tokenId);

    /// @notice Values `tokenId` at oracle prices.
    /// @dev Applies no risk policy of its own. The 10%-of-principal cap on counted fees and
    ///      the ±2% spot gate are risk parameters (§6.2, §5.2), so they are applied by the
    ///      market using the policy's numbers — this contract only reports the pieces. That
    ///      keeps a change to a risk parameter from requiring a new valuer.
    function value(
        uint256 tokenId
    ) external view returns (Valuation memory);

    /// @notice Values `tokenId` at the prices liquidation decides on (§4.3, §8 step 1).
    /// @dev Identical arithmetic to `value`, reading `IPriceOracle.priceForLiquidation`
    ///      instead of `price`. The two sources return the same number in the MVP, and the
    ///      split exists so they can diverge without every liquidation caller changing:
    ///      §5.2 gives the meme tier a liquidation price of its own (TWAP, or spot during a
    ///      genuine crash), and §5.2 requires liquidation to keep working in exactly the
    ///      conditions that block borrowing. A liquidation that read the borrow price would
    ///      inherit that blocking, and a position that cannot be liquidated is bad debt.
    function valueForLiquidation(
        uint256 tokenId
    ) external view returns (Valuation memory);

    /// @notice The fees `tokenId` has accrued and not yet collected, in raw token units.
    /// @dev The same `fees0`/`fees1` as `value`, read without any price, so it answers while the
    ///      oracle does not. These are exactly what the next `DECREASE_LIQUIDITY` on the position
    ///      realises, unless something moves the pool's fee growth first in the same transaction:
    ///      a swap or donate made by the pool's hook from inside that decrease (FAR-52).
    function feesOf(
        uint256 tokenId
    ) external view returns (uint256 fees0, uint256 fees1);
}
