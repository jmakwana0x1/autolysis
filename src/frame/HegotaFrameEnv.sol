// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IFrameEnv} from "./IFrameEnv.sol";
import {TxView, FrameView} from "./FrameTypes.sol";

/// @title HegotaFrameEnv
/// @notice Devnet implementation of `IFrameEnv`. Solidity cannot emit the draft frame opcodes, so each
///         opcode lives in a tiny raw-bytecode "probe cell" deployed by `script/DeployFrameCells.s.sol`
///         from the opcode numbers pinned in `deployments/probes.json` (see `FrameCellBytecode`).
/// @dev Cell calling convention: calldata = abi.encode(uint256 a, uint256 b); the cell executes
///      `OP(a, b)` (or `OP(a)`) and returns one 32-byte word. The APPROVE cell is DELEGATECALLed so that
///      ADDRESS stays equal to the approving account.
contract HegotaFrameEnv is IFrameEnv {
    struct Cells {
        address txParam; // TXPARAM(param, index)
        address frameParam; // FRAMEPARAM(param, frameIndex)
        address frameDataLoad; // FRAMEDATALOAD(offset, frameIndex)
        address approveCell; // APPROVE(scope)
    }

    /// Parameter indices, as pinned by probe #1 (draft numbering differs from the published ERC).
    struct Params {
        uint256 txSender;
        uint256 txNonceKeyCount;
        uint256 txNonceKey; // indexed by key position
        uint256 txSequence;
        uint256 txFee; // TXPARAM 0x06 in the sidecar draft
        uint256 txExpiry;
        uint256 txFrameCount;
        uint256 txCurrentFrame;
        uint256 frMode;
        uint256 frTarget;
        uint256 frGasLimit;
        uint256 frStateLimit;
        uint256 frValue;
        uint256 frDataSize;
    }

    address public immutable TX_PARAM;
    address public immutable FRAME_PARAM;
    address public immutable FRAME_DATA_LOAD;
    address public immutable APPROVE_CELL;
    bytes32 public immutable PARAMS_HASH;

    uint256 internal constant MAX_DATA = 256;

    Params internal p;

    error CellFailed(address cell, uint256 a, uint256 b);
    error NotDelegated();

    address private immutable SELF;

    constructor(Cells memory cells, Params memory params_) {
        TX_PARAM = cells.txParam;
        FRAME_PARAM = cells.frameParam;
        FRAME_DATA_LOAD = cells.frameDataLoad;
        APPROVE_CELL = cells.approveCell;
        p = params_;
        PARAMS_HASH = keccak256(abi.encode(params_));
        SELF = address(this);
    }

    function params() external view returns (Params memory) {
        return p;
    }

    function load() external view returns (TxView memory v) {
        Params memory q = p;
        v.sender = address(uint160(_cell(TX_PARAM, q.txSender, 0)));
        uint256 keyCount = _cell(TX_PARAM, q.txNonceKeyCount, 0);
        v.nonceKeys = new uint256[](keyCount);
        for (uint256 i; i < keyCount; ++i) {
            v.nonceKeys[i] = _cell(TX_PARAM, q.txNonceKey, i);
        }
        v.sequence = _cell(TX_PARAM, q.txSequence, 0);
        v.feeParam = _cell(TX_PARAM, q.txFee, 0);
        v.expiry = _cell(TX_PARAM, q.txExpiry, 0);
        v.currentFrame = _cell(TX_PARAM, q.txCurrentFrame, 0);
        uint256 n = _cell(TX_PARAM, q.txFrameCount, 0);
        v.frames = new FrameView[](n);
        for (uint256 i; i < n; ++i) {
            FrameView memory f = v.frames[i];
            f.mode = uint8(_cell(FRAME_PARAM, q.frMode, i));
            f.target = address(uint160(_cell(FRAME_PARAM, q.frTarget, i)));
            f.gasLimit = _cell(FRAME_PARAM, q.frGasLimit, i);
            f.stateLimit = _cell(FRAME_PARAM, q.frStateLimit, i);
            f.value = _cell(FRAME_PARAM, q.frValue, i);
            uint256 size = _cell(FRAME_PARAM, q.frDataSize, i);
            // Only the canonical calldata shape is ever accepted, so oversized frames are represented
            // by a 257-byte zero buffer: it fails the calldata-length rule without VERIFY having to
            // spend unbounded gas loading hostile data.
            if (size > MAX_DATA) {
                f.data = new bytes(MAX_DATA + 1);
                continue;
            }
            bytes memory data = new bytes(size);
            for (uint256 off; off < size; off += 32) {
                uint256 word = _cell(FRAME_DATA_LOAD, off, i);
                if (off + 32 > size) {
                    // keep the buffer exact: clear bytes beyond `size`
                    uint256 keep = (size - off) * 8;
                    word = (word >> (256 - keep)) << (256 - keep);
                }
                assembly ("memory-safe") {
                    mstore(add(add(data, 32), off), word)
                }
            }
            f.data = data;
        }
    }

    function approve(uint256 scope) external {
        if (address(this) == SELF) revert NotDelegated();
        (bool ok,) = APPROVE_CELL.delegatecall(abi.encode(scope, uint256(0)));
        if (!ok) revert CellFailed(APPROVE_CELL, scope, 0);
    }

    function _cell(address cell, uint256 a, uint256 b) internal view returns (uint256 out) {
        (bool ok, bytes memory ret) = cell.staticcall(abi.encode(a, b));
        if (!ok || ret.length < 32) revert CellFailed(cell, a, b);
        out = abi.decode(ret, (uint256));
    }
}
