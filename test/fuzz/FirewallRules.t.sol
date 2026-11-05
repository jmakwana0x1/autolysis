// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {FirewallRules} from "../../src/libraries/FirewallRules.sol";
import {TxView, FrameView, FrameTypes} from "../../src/frame/FrameTypes.sol";
import {ProbeConstants} from "../../src/generated/ProbeConstants.sol";

/// @notice The firewall contract: approve exactly one transaction shape per (position, step). Start
///         from the canonical tx, mutate exactly one field, and assert VERIFY rejects. The positive
///         property: the unmutated canonical tx always approves.
contract FirewallRulesTest is Test {
    address constant ACCOUNT = address(0xA11CE);
    address constant MARKET = address(0x3A12E7);
    uint256 constant POS = 42;
    uint256 constant ROUND = 7;
    uint256 constant SEQ = 3;
    uint256 constant NOW = 1_000_000;

    function _expect() internal pure returns (FirewallRules.Expect memory e) {
        e.account = ACCOUNT;
        e.market = MARKET;
        e.positionId = POS;
        e.roundId = ROUND;
        e.feeCapTotal = 1_000_000 gwei;
        e.firstUseStateCost = ProbeConstants.FIRST_USE_KEY_STATE_GAS;
        e.keyIsNew = true;
    }

    function _canonical() internal pure returns (TxView memory v) {
        v.sender = ACCOUNT;
        v.nonceKeys = new uint256[](1);
        v.nonceKeys[0] = FirewallRules.nonceKey(MARKET, POS);
        v.sequence = SEQ;
        v.feeParam = 1_000_000 gwei; // total-cost format (matches ProbeConstants default)
        v.currentFrame = 0;
        v.frames = new FrameView[](2);
        v.frames[0] = FrameView({
            mode: FrameTypes.MODE_VERIFY,
            target: ACCOUNT,
            gasLimit: 200_000,
            stateLimit: ProbeConstants.FIRST_USE_KEY_STATE_GAS + 50_000,
            value: 0,
            allowedScope: FrameTypes.SCOPE_EXECUTION_AND_PAYMENT,
            data: abi.encodeWithSelector(FirewallRules.VERIFY_SEL)
        });
        v.frames[1] = FrameView({
            mode: FrameTypes.MODE_SENDER,
            target: ACCOUNT,
            gasLimit: 300_000,
            stateLimit: 0,
            value: 0,
            allowedScope: FrameTypes.SCOPE_NONE,
            data: abi.encodeWithSelector(FirewallRules.EXECUTE_SEL, POS, ROUND)
        });
    }

    // Positive property: the canonical tx approves.
    function test_canonicalApproves() public pure {
        assertEq(uint256(FirewallRules.check(_canonical(), _expect())), uint256(FirewallRules.Reject.OK));
    }

    function _rejects(TxView memory v) internal pure {
        FirewallRules.Reject r = FirewallRules.check(v, _expect());
        assertTrue(r != FirewallRules.Reject.OK, "mutation was not rejected");
    }

    // --- single-field mutations: each must flip OK -> reject ---

    function test_mut_sender(address x) public pure {
        vm.assume(x != ACCOUNT);
        TxView memory v = _canonical();
        v.sender = x;
        _rejects(v);
    }

    function test_mut_frameCount() public pure {
        TxView memory v = _canonical();
        FrameView[] memory f = new FrameView[](3);
        f[0] = v.frames[0];
        f[1] = v.frames[1];
        f[2] = v.frames[1];
        v.frames = f;
        _rejects(v);

        TxView memory v2 = _canonical();
        FrameView[] memory g = new FrameView[](1);
        g[0] = v2.frames[0];
        v2.frames = g;
        _rejects(v2);
    }

    function test_mut_frameOrder() public pure {
        TxView memory v = _canonical();
        FrameView memory tmp = v.frames[0];
        v.frames[0] = v.frames[1];
        v.frames[1] = tmp;
        _rejects(v);
    }

    function test_mut_verifyMode(uint8 m) public pure {
        vm.assume(m != FrameTypes.MODE_VERIFY);
        TxView memory v = _canonical();
        v.frames[0].mode = m;
        _rejects(v);
    }

    function test_mut_verifyAllowedScope(uint256 scope) public pure {
        vm.assume(scope != FrameTypes.SCOPE_EXECUTION_AND_PAYMENT);
        TxView memory v = _canonical();
        v.frames[0].allowedScope = scope;
        _rejects(v);
    }

    function test_mut_execMode(uint8 m) public pure {
        vm.assume(m != FrameTypes.MODE_SENDER);
        TxView memory v = _canonical();
        v.frames[1].mode = m;
        _rejects(v);
    }

    function test_mut_verifyTarget(address x) public pure {
        vm.assume(x != ACCOUNT);
        TxView memory v = _canonical();
        v.frames[0].target = x;
        _rejects(v);
    }

    function test_mut_execTarget(address x) public pure {
        vm.assume(x != ACCOUNT);
        TxView memory v = _canonical();
        v.frames[1].target = x;
        _rejects(v);
    }

    function test_mut_execSelector(bytes4 sel) public pure {
        vm.assume(sel != FirewallRules.EXECUTE_SEL);
        TxView memory v = _canonical();
        v.frames[1].data = abi.encodeWithSelector(sel, POS, ROUND);
        _rejects(v);
    }

    function test_mut_calldataLen(uint8 extra) public pure {
        vm.assume(extra > 0 && extra < 64);
        TxView memory v = _canonical();
        v.frames[1].data = abi.encodePacked(v.frames[1].data, new bytes(extra));
        _rejects(v);
    }

    function test_mut_positionId(uint256 x) public pure {
        vm.assume(x != POS);
        TxView memory v = _canonical();
        v.frames[1].data = abi.encodeWithSelector(FirewallRules.EXECUTE_SEL, x, ROUND);
        _rejects(v);
    }

    function test_mut_roundId(uint256 x) public pure {
        vm.assume(x != ROUND);
        TxView memory v = _canonical();
        v.frames[1].data = abi.encodeWithSelector(FirewallRules.EXECUTE_SEL, POS, x);
        _rejects(v);
    }

    function test_mut_keyValue(uint256 x) public pure {
        uint256 good = FirewallRules.nonceKey(MARKET, POS);
        vm.assume(x != good && x >> 248 == 0);
        TxView memory v = _canonical();
        v.nonceKeys[0] = x;
        _rejects(v);
    }

    function test_mut_keyTopByte(uint8 top) public pure {
        vm.assume(top != 0);
        TxView memory v = _canonical();
        v.nonceKeys[0] = (uint256(top) << 248) | FirewallRules.nonceKey(MARKET, POS);
        _rejects(v);
    }

    function test_mut_secondKey(uint256 extra) public pure {
        TxView memory v = _canonical();
        uint256[] memory keys = new uint256[](2);
        keys[0] = v.nonceKeys[0];
        keys[1] = extra;
        v.nonceKeys = keys;
        _rejects(v);
    }

    function test_mut_feeAboveCap(uint256 fee) public pure {
        fee = bound(fee, 1_000_000 gwei + 1, type(uint128).max);
        TxView memory v = _canonical();
        v.feeParam = fee;
        _rejects(v);
    }

    function test_mut_stateBudgetTooLow(uint256 sl) public pure {
        sl = bound(sl, 0, ProbeConstants.FIRST_USE_KEY_STATE_GAS - 1);
        TxView memory v = _canonical();
        v.frames[0].stateLimit = sl;
        _rejects(v);
    }

    // No-op: if the key is not new, a low state budget is fine (don't over-reject).
    function test_notNewKeyAllowsLowBudget() public pure {
        TxView memory v = _canonical();
        v.frames[0].stateLimit = 0;
        FirewallRules.Expect memory e = _expect();
        e.keyIsNew = false;
        assertEq(uint256(FirewallRules.check(v, e)), uint256(FirewallRules.Reject.OK));
    }
}
