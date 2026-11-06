// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Deployers} from "v4-core-test/utils/Deployers.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolModifyLiquidityTest} from "v4-core/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {SortTokens} from "v4-core-test/utils/SortTokens.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

/// @notice Shared setup for the Unichain mainnet fork proofs (chain 130), against OFFICIAL contracts.
/// @dev Addresses: Uniswap v4 PoolManager per Uniswap's deployments page
///      (developers.uniswap.org/docs/protocols/v4/deployments, Unichain) and confirmed on chain: its runtime
///      bytecode equals the devnet's official v4 PoolManager except the immutable self-address and the
///      metadata tail. 1inch Aqua per the 1inch registry (official address in PLAN-v4.4 C2).
///      Run with UNICHAIN_RPC_URL (+ UNICHAIN_FORK_BLOCK to pin, CI: 63190327); skipped without it.
abstract contract UnichainFork is Deployers {
    address constant OFFICIAL_POOL_MANAGER = 0x1F98400000000000000000000000000000000004;
    address constant OFFICIAL_AQUA = 0x1111113CCf1426A8E30e2bfF5E005d929bF6a90a;

    /// Selects the fork, or skips the test when no RPC is configured (so `just test` stays offline).
    function _selectUnichainFork() internal returns (bool) {
        string memory rpc = vm.envOr("UNICHAIN_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return false;
        }
        uint256 forkBlock = vm.envOr("UNICHAIN_FORK_BLOCK", uint256(0));
        if (forkBlock == 0) vm.createSelectFork(rpc);
        else vm.createSelectFork(rpc, forkBlock);
        require(block.chainid == 130, "not Unichain mainnet");
        require(OFFICIAL_POOL_MANAGER.code.length > 0, "official PoolManager has no code on this fork");
        require(OFFICIAL_AQUA.code.length > 0, "official Aqua has no code on this fork");
        emit log_named_uint("fork: Unichain block", block.number);
        emit log_named_address("fork: official PoolManager", OFFICIAL_POOL_MANAGER);
        return true;
    }

    /// The official PoolManager plus the two v4-core test routers we need (liquidity, plain swaps). Unlike
    /// `deployFreshManagerAndRouters` this never calls owner-only manager functions.
    function _useOfficialManager() internal {
        manager = IPoolManager(OFFICIAL_POOL_MANAGER);
        modifyLiquidityRouter = new PoolModifyLiquidityTest(manager);
        swapRouter = new PoolSwapTest(manager);
    }

    /// Two fresh test tokens, sorted, approved to the routers above.
    function _officialManagerCurrencies() internal returns (Currency, Currency) {
        MockERC20[] memory t = deployTokens(2, 2 ** 255);
        for (uint256 i; i < 2; ++i) {
            t[i].approve(address(modifyLiquidityRouter), type(uint256).max);
            t[i].approve(address(swapRouter), type(uint256).max);
        }
        (currency0, currency1) = SortTokens.sort(t[0], t[1]);
        return (currency0, currency1);
    }
}
