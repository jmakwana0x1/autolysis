// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IRoundFeed {
    struct Round {
        uint256 price; // collateral price in debt units, WAD
        uint256 timestamp;
        bool valid;
    }

    function latestRound() external view returns (uint256 roundId);
    function getRound(uint256 roundId) external view returns (Round memory);

    /// @notice The price to use for a liquidation citing `roundId`, reverting if the round is outside
    ///         the acceptable band or tripped the breaker. One guarantee: a liquidation never uses a
    ///         price outside the band.
    function priceForLiquidation(uint256 roundId) external view returns (uint256 price);

    /// @notice The price for VERIFY (validation context: index window, band, breaker; no TIMESTAMP).
    function checkRoundForVerify(uint256 roundId) external view returns (uint256 price);
}
