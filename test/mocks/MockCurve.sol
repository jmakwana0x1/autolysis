// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ISwapVenue} from "../../src/interfaces/ISwapVenue.sol";
import {IRoundFeed} from "../../src/interfaces/IRoundFeed.sol";
import {IERC20} from "../../src/interfaces/IERC20.sol";

/// @notice Plain constant-price curve standing in for the v4 pool in Phase 1. Sells collateral for
///         debt token at the feed's latest price (optionally with a slippage haircut in bps).
contract MockCurve is ISwapVenue {
    uint256 constant WAD = 1e18;
    IERC20 public immutable collateral;
    IERC20 public immutable debt;
    IRoundFeed public immutable feed;
    uint256 public haircutWad; // sale haircut as a WAD fraction (0.01e18 == 1%)
    uint256 public roundPrice; // cited-round price set by the market (0 -> use latest)

    constructor(IERC20 collateral_, IERC20 debt_, IRoundFeed feed_) {
        collateral = collateral_;
        debt = debt_;
        feed = feed_;
    }

    /// Set the haircut in basis points (50 == 0.5%); stored as WAD.
    function setHaircut(uint256 bps) external {
        haircutWad = bps * WAD / 10_000;
    }

    function setRoundPrice(uint256 price) external {
        roundPrice = price;
    }

    function sellCollateral(uint256 collateralIn, uint256 minDebtOut) external returns (uint256 debtOut) {
        // Collateral already transferred in (settle-before-swap). Model a venue charging exactly
        // `haircutWad`, flooring the output the same way the step's minOut does, so a haircut up to the
        // priced slippage clears minOut to the wei.
        uint256 price = roundPrice != 0 ? roundPrice : feed.getRound(feed.latestRound()).price;
        uint256 effPrice = price * (WAD - haircutWad) / WAD;
        debtOut = collateralIn * effPrice / WAD;
        require(debtOut >= minDebtOut, "slippage");
        debt.transfer(msg.sender, debtOut);
    }
}
