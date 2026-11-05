// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IMakerStrategy} from "./IMakerStrategy.sol";
import {AquaPricing} from "./AquaPricing.sol";
import {IRoundFeed} from "../interfaces/IRoundFeed.sol";
import {IERC20Min} from "../interfaces/IERC20Min.sol";

/// @title AutolysisAquaRouter
/// @notice Our redeploy of the SwapVM maker engine with a `LiquidationGate`: maker strategies can only
///         be filled during a gated liquidation whose taker is the backstop hook. Guarantees:
///         - No one outside a liquidation can fill a maker strategy (the gate).
///         - Only allowlisted strategy templates are ever executed (template allowlist).
///         - quote() and swap() use the same pricing (AquaPricing), so a quote equals the fill.
///         - A maker that withdrew between quote and fill, or is empty, is skipped; the next tier runs.
///         - A strategy that burns gas is cut off by a per-maker gas stipend and skipped.
/// @dev Collateral (what the taker sells) is priced in USDC by the oracle. Makers provide USDC and
///      receive collateral. The router never custodies maker funds: it pulls USDC straight from maker
///      wallets via their strategy's `commit`, under a stipend.
contract AutolysisAquaRouter {
    using AquaPricing for uint256;

    struct Maker {
        IMakerStrategy strategy;
        uint256 baseSpreadBps;
        bool active;
    }

    address public immutable owner;
    IRoundFeed public immutable feed;
    IERC20Min public immutable usdc;
    IERC20Min public immutable collateral;
    address public hook; // the only allowed taker (set once by owner)

    uint256 public constant MAKER_GAS_STIPEND = 120_000;
    uint256 public volAddonBps; // governance/vol oracle sets this; part of the Decay surcharge

    // template allowlist: strategy code hash => allowed
    mapping(bytes32 => bool) public allowedTemplate;
    Maker[] public makers;

    // LiquidationGate: set only by the hook for the duration of one fill.
    bool public gateOpen;

    error NotOwner();
    error NotHook();
    error GateClosed();
    error TemplateNotAllowed();

    event HookSet(address hook);
    event TemplateAllowed(bytes32 codehash, bool allowed);
    event MakerRegistered(uint256 indexed id, address strategy);
    event MakerFilled(uint256 indexed id, uint256 usdcMoved, uint256 collateralOut);

    constructor(IRoundFeed feed_, IERC20Min usdc_, IERC20Min collateral_, address owner_) {
        feed = feed_;
        usdc = usdc_;
        collateral = collateral_;
        owner = owner_;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    function setHook(address hook_) external onlyOwner {
        hook = hook_;
        emit HookSet(hook_);
    }

    function setVolAddon(uint256 bps) external onlyOwner {
        volAddonBps = bps;
    }

    function allowTemplate(bytes32 codehash, bool allowed) external onlyOwner {
        allowedTemplate[codehash] = allowed;
        emit TemplateAllowed(codehash, allowed);
    }

    /// @notice Register a maker strategy. Reverts unless the strategy contract's code hash is an
    ///         allowlisted template — only allowlisted templates are ever tried.
    function registerMaker(IMakerStrategy strategy, uint256 baseSpreadBps) external returns (uint256 id) {
        if (!allowedTemplate[address(strategy).codehash]) revert TemplateNotAllowed();
        id = makers.length;
        makers.push(Maker({strategy: strategy, baseSpreadBps: baseSpreadBps, active: true}));
        emit MakerRegistered(id, address(strategy));
    }

    function makerCount() external view returns (uint256) {
        return makers.length;
    }

    function _effPrice(uint256 baseSpreadBps) internal view returns (uint256) {
        uint256 oracle = feed.getRound(feed.latestRound()).price;
        return oracle.effectivePrice(baseSpreadBps, volAddonBps);
    }

    /// @notice Quote the USDC a fill of `collateralIn` would raise across makers, at current prices.
    ///         Uses the same pricing and the same skip rules as `fill` (a view, so no stipend / no
    ///         state): quote equals fill under unchanged state.
    function quote(uint256 collateralIn) external view returns (uint256 usdcOut, uint256 collateralUsed) {
        uint256 remaining = collateralIn;
        for (uint256 i; i < makers.length && remaining > 0; ++i) {
            Maker storage m = makers[i];
            if (!m.active) continue;
            uint256 eff = _effPrice(m.baseSpreadBps);
            if (eff == 0) continue;
            uint256 makerUsdc = m.strategy.available();
            if (makerUsdc == 0) continue;
            uint256 makerCollateral = AquaPricing.collateralForUsdc(makerUsdc, eff);
            uint256 take = makerCollateral < remaining ? makerCollateral : remaining;
            uint256 usdc_ = AquaPricing.usdcForCollateral(take, eff);
            usdcOut += usdc_;
            collateralUsed += take;
            remaining -= take;
        }
    }

    /// @notice Fill up to `collateralIn` collateral from makers, raising USDC to `to`. Gated: only the
    ///         hook may call, and only while the gate is open. Returns USDC raised and collateral used.
    function fill(uint256 collateralIn, address to) external returns (uint256 usdcOut, uint256 collateralUsed) {
        if (msg.sender != hook) revert NotHook();
        if (!gateOpen) revert GateClosed();

        uint256 remaining = collateralIn;
        for (uint256 i; i < makers.length && remaining > 0; ++i) {
            Maker storage m = makers[i];
            if (!m.active) continue;
            uint256 eff = _effPrice(m.baseSpreadBps);
            if (eff == 0) continue;

            // How much this maker could supply (under a gas stipend so a gas-bomb strategy is cut off).
            uint256 makerUsdc = _availableStipended(m.strategy);
            if (makerUsdc == 0) continue; // empty / rugged / gas bomb -> skip to next tier

            uint256 makerCollateral = AquaPricing.collateralForUsdc(makerUsdc, eff);
            uint256 take = makerCollateral < remaining ? makerCollateral : remaining;
            uint256 want = AquaPricing.usdcForCollateral(take, eff);
            if (want == 0) continue;

            uint256 moved = _commitStipended(m.strategy, to, want);
            if (moved == 0) continue; // maker withdrew between quote and fill -> skip

            // Credit the maker the collateral their USDC bought (rounded to what they actually funded).
            uint256 collForMoved = AquaPricing.collateralForUsdc(moved, eff);
            if (collForMoved > remaining) collForMoved = remaining;
            // Collateral is delivered to makers by the hook after the swap settles; here we only account.
            usdcOut += moved;
            collateralUsed += collForMoved;
            remaining -= collForMoved;
            emit MakerFilled(i, moved, collForMoved);
        }
    }

    /// @notice Open/close the gate. Only the hook toggles it, bracketing one fill.
    function setGate(bool open) external {
        if (msg.sender != hook) revert NotHook();
        gateOpen = open;
    }

    function _availableStipended(IMakerStrategy s) internal view returns (uint256 amt) {
        try s.available{gas: MAKER_GAS_STIPEND}() returns (uint256 a) {
            amt = a;
        } catch {
            amt = 0;
        }
    }

    function _commitStipended(IMakerStrategy s, address to, uint256 amount) internal returns (uint256 moved) {
        try s.commit{gas: MAKER_GAS_STIPEND}(to, amount) returns (uint256 m) {
            moved = m;
        } catch {
            moved = 0;
        }
    }
}
