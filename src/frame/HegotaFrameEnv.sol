// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IFrameEnv} from "./IFrameEnv.sol";
import {TxView, FrameView} from "./FrameTypes.sol";
import {HegotaSupport, Devnet, Scope, TxParam, FrameParam} from "@forshtat/hegota-support/contracts/HegotaSupport.sol";

/// @title HegotaFrameEnv
/// @notice Devnet implementation of `IFrameEnv`. It owns no opcode bytes: it inherits `HegotaSupport`
///         (hegota-support @ 2377188), whose `txparam` / `frameparam` / `framedataload` / `approve`
///         are the real frame opcodes wrapped as Solidity functions, each a per-contract immutable Yul
///         helper. `approve` acts on the executing account, so the account reaches it through the same
///         DELEGATECALL it already uses; the reads are STATICCALLs.
/// @dev The chosen devnet is the public alt-mempool tracer (ERC8421_WORKSHOP, chain 1337).
contract HegotaFrameEnv is IFrameEnv, HegotaSupport {
    uint256 internal constant MAX_DATA = 256;

    constructor() HegotaSupport(Devnet.ERC8421_WORKSHOP) {}

    function load() external view returns (TxView memory v) {
        v.sender = address(uint160(txparam(TxParam.SENDER)));
        uint256 keyCount = txparam(TxParam.NONCE_KEY_COUNT);
        v.nonceKeys = new uint256[](keyCount);
        // The canonical liquidation uses exactly one key; read key 0 (0x10). Additional keys only need
        // to be visible as "more than one" so the firewall can reject them, so read key 0 and leave the
        // rest zero — a second key makes keyCount != 1, which FirewallRules rejects.
        if (keyCount >= 1) v.nonceKeys[0] = txparam(TxParam.NONCE_KEY_0);
        v.sequence = txparam(TxParam.NONCE);
        v.feeParam = txparam(TxParam.MAX_COST);
        v.currentFrame = txparam(TxParam.CURRENT_FRAME_INDEX);

        uint256 n = txparam(TxParam.FRAME_COUNT);
        v.frames = new FrameView[](n);
        for (uint256 i; i < n; ++i) {
            FrameView memory f = v.frames[i];
            f.mode = uint8(frameparam(i, FrameParam.MODE));
            f.target = address(uint160(frameparam(i, FrameParam.RESOLVED_TARGET)));
            f.gasLimit = frameparam(i, FrameParam.EXECUTION_GAS_LIMIT);
            f.stateLimit = frameparam(i, FrameParam.STATE_GAS_LIMIT);
            f.value = frameparam(i, FrameParam.VALUE);
            f.allowedScope = frameparam(i, FrameParam.ALLOWED_SCOPE);
            uint256 size = frameparam(i, FrameParam.DATA_LENGTH);
            // Cap reads: the canonical calldata is tiny, and anything longer fails the length rule, so a
            // hostile oversize frame need not be loaded in full.
            if (size > MAX_DATA) {
                f.data = new bytes(MAX_DATA + 1);
                continue;
            }
            bytes memory data = new bytes(size);
            for (uint256 off; off < size; off += 32) {
                bytes32 word = framedataload(off, i);
                assembly ("memory-safe") {
                    mstore(add(add(data, 32), off), word)
                }
            }
            f.data = data;
        }
    }

    function maxCost() external view returns (uint256) {
        return txparam(TxParam.MAX_COST);
    }

    function approve(uint256 scope) external {
        // Reached by DELEGATECALL from the account, so APPROVE acts on the account. `scope` is a Scope.
        approve(Scope(scope));
    }
}
