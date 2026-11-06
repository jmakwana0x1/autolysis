// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {SwapVMTier1Base} from "../integration/C1_SwapVMTier1.t.sol";

/// C2 (PLAN-v4.4), ON FORK: the C1 liquidation flow against the OFFICIAL 1inch Aqua registry on Unichain
/// mainnet (chain 130). Everything else (our gated SwapVM router, pricer, BackstopHook, market, a fresh
/// PoolManager, mock tokens) is deployed onto the fork; only Aqua is the live contract. Run with
/// `just fork-c2` (sets UNICHAIN_RPC_URL, optional UNICHAIN_FORK_BLOCK); skipped otherwise, so `just test`
/// stays offline.
contract C2OfficialAquaForkTest is SwapVMTier1Base {
    address constant OFFICIAL_AQUA = 0x1111113CCf1426A8E30e2bfF5E005d929bF6a90a;

    function _beforeSetUp() internal override {
        string memory rpc = vm.envOr("UNICHAIN_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        // UNICHAIN_FORK_BLOCK pins the fork (CI uses 63190327, the block C2 was first recorded at), so the
        // run is reproducible and Foundry's RPC cache can serve it.
        uint256 forkBlock = vm.envOr("UNICHAIN_FORK_BLOCK", uint256(0));
        if (forkBlock == 0) vm.createSelectFork(rpc);
        else vm.createSelectFork(rpc, forkBlock);
        require(block.chainid == 130, "not Unichain mainnet");
        require(OFFICIAL_AQUA.code.length > 0, "official Aqua has no code on this fork");
        emit log_named_uint("C2 fork: Unichain block", block.number);
        emit log_named_bytes32("C2 fork: official Aqua codehash", OFFICIAL_AQUA.codehash);
    }

    function _aqua() internal pure override returns (address) {
        return OFFICIAL_AQUA;
    }
}
