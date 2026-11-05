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
    uint256 public haircutBps;

    constructor(IERC20 collateral_, IERC20 debt_, IRoundFeed feed_) {
        collateral = collateral_;
        debt = debt_;
        feed = feed_;
    }

    function setHaircut(uint256 bps) external {
        haircutBps = bps;
    }

    function sellCollateral(uint256 collateralIn, uint256 minDebtOut) external returns (uint256 debtOut) {
        // Collateral already transferred in (settle-before-swap).
        uint256 price = feed.getRound(feed.latestRound()).price;
        debtOut = (collateralIn * price / WAD) * (10_000 - haircutBps) / 10_000;
        require(debtOut >= minDebtOut, "slippage");
        debt.transfer(msg.sender, debtOut);
    }
}
