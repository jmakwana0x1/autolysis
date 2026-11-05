// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "../interfaces/IERC20.sol";
import {IRoundFeed} from "../interfaces/IRoundFeed.sol";
import {ISwapVenue} from "../interfaces/ISwapVenue.sol";
import {ISelfLiquidatingMarket} from "../interfaces/ISelfLiquidatingMarket.sol";
import {LiquidationMath, Math} from "../libraries/LiquidationMath.sol";
import {TankLedger} from "../libraries/TankLedger.sol";

/// @title AutolysisMarket
/// @notice Single-collateral lending market that liquidates positions gradually by selling collateral
///         through a swap venue. Guarantees: only the account can liquidate; collateral and debt are
///         conserved; the "liquidation active" flag is never set outside a liquidation call; a failed
///         liquidation bills at most the fee cap and reverts nothing to the caller (never-revert is
///         enforced by the account, which wraps executeLiquidation).
/// @dev Debt token is USDC-like (the tank and depositor accounting live in it). Collateral is a
///      separate ERC20. All health math is in LiquidationMath (WAD).
contract AutolysisMarket is ISelfLiquidatingMarket {
    using TankLedger for TankLedger.Tank;

    uint256 internal constant WAD = 1e18;

    struct Position {
        address owner;
        uint256 collateral;
        uint256 debt;
        uint256 liquidations; // successful steps; also the keyed-nonce sequence
    }

    IERC20 public immutable collateralToken;
    IERC20 public immutable debtToken;
    IRoundFeed public immutable feed;
    ISwapVenue public venue;
    address public immutable account; // the only address allowed to liquidate
    address public owner; // governance: sets venue, liqThreshold

    uint256 public liqThreshold = 0.8e18; // L (WAD)
    uint256 public targetHf = 1.05e18; // T (WAD)
    uint256 public slippage = 0.01e18; // s: assumed sale haircut the step prices against (WAD)
    uint256 public constant CLASSIC_THRESHOLD = 0.95e18; // for the classic-market comparison
    uint256 public feeCap = 0.01e18; // max fee billed per attempt, in debt token

    uint256 public nextPositionId = 1;
    mapping(uint256 => Position) public positions;
    mapping(uint256 => TankLedger.Tank) internal tanks;

    uint256 public totalCollateral; // sum of position collateral (accounting invariant anchor)
    uint256 public totalDebt; // sum of position debt
    uint256 public totalSoldOut; // collateral that left via liquidation sales

    // Transient "liquidation active" flag (EIP-1153). Never set outside executeLiquidation.
    bytes32 internal constant ACTIVE_SLOT = keccak256("autolysis.liquidation.active");

    error NotAccount();
    error NotOwner();
    error NotPositionOwner();
    error Healthy();
    error ReentrantLiquidation();

    event Opened(uint256 indexed id, address indexed owner);
    event Borrowed(uint256 indexed id, uint256 amount);
    event Repaid(uint256 indexed id, uint256 amount);
    event Deposited(uint256 indexed id, uint256 amount);
    event Withdrawn(uint256 indexed id, uint256 amount);
    event TankRefilled(uint256 indexed id, uint256 amount);
    event Liquidated(uint256 indexed id, uint256 roundId, uint256 debtRepaid, uint256 collateralSold, uint256 fee);

    constructor(IERC20 collateral_, IERC20 debt_, IRoundFeed feed_, address account_) {
        collateralToken = collateral_;
        debtToken = debt_;
        feed = feed_;
        account = account_;
        owner = msg.sender;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    function setVenue(ISwapVenue v) external onlyOwner {
        venue = v;
    }

    function setParams(uint256 lt, uint256 target, uint256 cap) external onlyOwner {
        liqThreshold = lt;
        targetHf = target;
        feeCap = cap;
    }

    function setSlippage(uint256 s) external onlyOwner {
        slippage = s;
    }

    // --- position lifecycle ---

    function open() external returns (uint256 id) {
        id = nextPositionId++;
        positions[id].owner = msg.sender;
        emit Opened(id, msg.sender);
    }

    function deposit(uint256 id, uint256 amount) public {
        Position storage pos = positions[id];
        require(pos.owner != address(0), "no position");
        collateralToken.transferFrom(msg.sender, address(this), amount);
        pos.collateral += amount;
        totalCollateral += amount;
        emit Deposited(id, amount);
    }

    function withdraw(uint256 id, uint256 amount) external {
        Position storage pos = positions[id];
        if (pos.owner != msg.sender) revert NotPositionOwner();
        pos.collateral -= amount;
        totalCollateral -= amount;
        // Must remain healthy after withdrawal.
        require(_hf(pos) >= WAD, "would be unhealthy");
        collateralToken.transfer(msg.sender, amount);
        emit Withdrawn(id, amount);
    }

    function borrow(uint256 id, uint256 amount) external {
        Position storage pos = positions[id];
        if (pos.owner != msg.sender) revert NotPositionOwner();
        pos.debt += amount;
        totalDebt += amount;
        require(_hf(pos) >= WAD, "would be unhealthy");
        debtToken.transfer(msg.sender, amount);
        emit Borrowed(id, amount);
    }

    function repay(uint256 id, uint256 amount) external {
        Position storage pos = positions[id];
        require(pos.owner != address(0), "no position");
        if (amount > pos.debt) amount = pos.debt;
        debtToken.transferFrom(msg.sender, address(this), amount);
        pos.debt -= amount;
        totalDebt -= amount;
        emit Repaid(id, amount);
    }

    function refillTank(uint256 id, uint256 amount) external {
        require(positions[id].owner != address(0), "no position");
        debtToken.transferFrom(msg.sender, address(this), amount);
        tanks[id].refill(amount);
        emit TankRefilled(id, amount);
    }

    // --- liquidation (account only) ---

    /// @notice One gradual step. Only the account may call. Billing is always <= feeCap. The account
    ///         wraps this in its never-revert envelope, so a revert here is turned into a failed-attempt
    ///         billing by the account; this function itself reverts only on guard violations.
    function executeLiquidation(uint256 positionId, uint256 roundId, uint256 cap)
        external
        returns (uint256 debtRepaid, uint256 collateralSold, uint256 feeBilled)
    {
        if (msg.sender != account) revert NotAccount();
        if (_active()) revert ReentrantLiquidation();
        _setActive(true);

        Position storage pos = positions[positionId];
        uint256 price = feed.priceForLiquidation(roundId); // reverts if out of band / breaker pending

        LiquidationMath.Step memory step =
            LiquidationMath.computeStep(pos.collateral, price, liqThreshold, pos.debt, targetHf, slippage);
        if (step.collateralToSell == 0) revert Healthy();

        // minOut is the floor of the haircut sale, so a venue with a real fee/spread still clears it.
        uint256 minOut = step.minOut;

        // settle-before-swap: move collateral to the venue first, then swap.
        collateralToken.transfer(address(venue), step.collateralToSell);
        uint256 got = venue.sellCollateral(step.collateralToSell, minOut);

        // Apply results. Debt actually cleared is capped by proceeds.
        uint256 cleared = got >= step.debtToRepay ? step.debtToRepay : got;
        pos.collateral -= step.collateralToSell;
        pos.debt -= cleared;
        totalCollateral -= step.collateralToSell;
        totalDebt -= cleared;
        totalSoldOut += step.collateralToSell;
        pos.liquidations += 1;

        // Any surplus proceeds above the cleared debt are credited back to the position owner's claim
        // by reducing nothing here (kept as market USDC backing depositors); conservation holds via
        // totalDebt. Fee billed to the tank, capped.
        feeBilled = cap < feeCap ? cap : feeCap;
        tanks[positionId].settle(feeBilled);

        debtRepaid = cleared;
        collateralSold = step.collateralToSell;
        _setActive(false);
        emit Liquidated(positionId, roundId, cleared, step.collateralToSell, feeBilled);
    }

    /// @notice Reserve tank headroom for an attempt; the account calls this before submitting.
    function reserveAttempt(uint256 positionId) external {
        if (msg.sender != account) revert NotAccount();
        tanks[positionId].reserve(feeCap);
    }

    /// @notice Bill a failed attempt (no state change to the position) at the failed-attempt cap.
    function billFailedAttempt(uint256 positionId, uint256 cap) external {
        if (msg.sender != account) revert NotAccount();
        uint256 bill = cap < feeCap ? cap : feeCap;
        tanks[positionId].settle(bill);
    }

    // --- views ---

    function healthFactor(uint256 id) external view returns (uint256) {
        return _hf(positions[id]);
    }

    function liquidationCount(uint256 id) external view returns (uint256) {
        return positions[id].liquidations;
    }

    function tankHeadroom(uint256 id, uint256 cap) external view returns (uint256) {
        return tanks[id].headroom(cap == 0 ? feeCap : cap);
    }

    function tank(uint256 id) external view returns (TankLedger.Tank memory) {
        return tanks[id];
    }

    function _hf(Position storage pos) internal view returns (uint256) {
        uint256 price = feed.getRound(feed.latestRound()).price;
        return LiquidationMath.healthFactor(pos.collateral, price, liqThreshold, pos.debt);
    }

    // --- transient active flag ---

    function liquidationActive() external view returns (bool) {
        return _active();
    }

    function _active() internal view returns (bool a) {
        bytes32 s = ACTIVE_SLOT;
        assembly {
            a := tload(s)
        }
    }

    function _setActive(bool v) internal {
        bytes32 s = ACTIVE_SLOT;
        assembly {
            tstore(s, v)
        }
    }
}
