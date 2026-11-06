// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {SwapVMTier1Base} from "../integration/C1_SwapVMTier1.t.sol";
import {UnichainFork} from "./UnichainFork.sol";

/// C2 (PLAN-v4.4), ON FORK: the C1 liquidation flow on a Unichain mainnet fork against OFFICIAL contracts:
/// the 1inch Aqua registry AND the Uniswap v4 PoolManager. Our gated SwapVM router, pricer, BackstopHook,
/// market and test tokens are deployed onto the fork. Run with `just fork-c2` (sets UNICHAIN_RPC_URL and
/// the pinned UNICHAIN_FORK_BLOCK); skipped otherwise, so `just test` stays offline.
contract C2OfficialAquaForkTest is SwapVMTier1Base, UnichainFork {
    function _beforeSetUp() internal override {
        if (!_selectUnichainFork()) return;
        emit log_named_bytes32("C2 fork: official Aqua codehash", OFFICIAL_AQUA.codehash);
    }

    function _setupManagerAndCurrencies() internal override {
        _useOfficialManager();
        _officialManagerCurrencies();
    }

    function _aqua() internal pure override returns (address) {
        return OFFICIAL_AQUA;
    }
}
