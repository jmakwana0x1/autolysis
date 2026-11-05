// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IMakerStrategy} from "./IMakerStrategy.sol";
import {IERC20Min} from "../interfaces/IERC20Min.sol";

/// @title WalletMakerStrategy
/// @notice The canonical allowlisted maker template. Deployed once as logic; each maker is an EIP-1167
///         clone of it, so every maker shares one runtime code hash — that single code hash is what the
///         router allowlists ("only allowlisted templates are ever tried"). A maker's USDC stays in
///         their own wallet and is pulled on commit via an allowance, capped at `maxSize`. Never reverts
///         on an empty wallet: it returns 0 so the router skips to the next tier.
/// @dev Clone-friendly: configuration lives in storage set by `initialize`, not in immutables (which
///      would change the runtime code and break the code-hash allowlist).
contract WalletMakerStrategy is IMakerStrategy {
    IERC20Min public usdc;
    address public wallet;
    address public router;
    uint256 public maxSize;
    bool private initialized;

    error AlreadyInitialized();
    error NotWallet();

    function initialize(IERC20Min usdc_, address wallet_, address router_, uint256 maxSize_) external {
        if (initialized) revert AlreadyInitialized();
        initialized = true;
        usdc = usdc_;
        wallet = wallet_;
        router = router_;
        maxSize = maxSize_;
    }

    function setMaxSize(uint256 s) external {
        if (msg.sender != wallet) revert NotWallet();
        maxSize = s;
    }

    function available() external view returns (uint256) {
        uint256 bal = usdc.balanceOf(wallet);
        uint256 allowed = usdc.allowance(wallet, address(this));
        uint256 a = bal < allowed ? bal : allowed;
        return a < maxSize ? a : maxSize;
    }

    function commit(address to, uint256 usdcAmount) external returns (uint256 moved) {
        if (msg.sender != router) return 0;
        uint256 cap = this.available();
        moved = usdcAmount < cap ? usdcAmount : cap;
        if (moved == 0) return 0;
        usdc.transferFrom(wallet, to, moved);
    }
}
