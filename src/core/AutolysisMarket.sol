// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "../interfaces/IERC20.sol";
import {IRoundFeed} from "../interfaces/IRoundFeed.sol";
import {ISwapVenue} from "../interfaces/ISwapVenue.sol";
import {ISelfLiquidatingMarket} from "../interfaces/ISelfLiquidatingMarket.sol";
import {LiquidationMath, Math} from "../libraries/LiquidationMath.sol";
import {IWETH} from "../interfaces/IWETH.sol";

/// @title AutolysisMarket
/// @notice Single-collateral lending market that liquidates positions gradually by selling collateral
///         through a swap venue. Guarantees: only the account can liquidate; collateral and debt are
///         conserved; the "liquidation active" flag is never set outside a liquidation call; a failed
///         liquidation bills at most the fee cap and reverts nothing to the caller (never-revert is
///         enforced by the account, which wraps executeLiquidation).
/// @dev Debt token is USDC-like (the tank and depositor accounting live in it). Collateral is a
///      separate ERC20. All health math is in LiquidationMath (WAD).
contract AutolysisMarket is ISelfLiquidatingMarket {
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

    uint256 public constant FEE_CAP_BPS = 30; // gas fee cap: 0.3% of the collateral sold
    uint256 public maxFailedGasBill = 0.02e18; // MAX_FAILED_GAS_BILL (wei of WETH collateral)
    uint256 public totalFeeBilled; // lifetime collateral taken as gas fees (ETH sent to the account)
    uint256 public badDebt; // debt written off against depositors (sale could not cover it)
    uint256 public totalWithdrawable; // USDC owed back to borrowers as liquidation surplus
    mapping(address => uint256) public withdrawableOf;

    uint256 public liqThreshold = 0.8e18; // L (WAD)
    uint256 public targetHf = 1.05e18; // T (WAD)
    uint256 public slippage = 0.01e18; // s: assumed sale haircut the step prices against (WAD)
    uint256 public constant CLASSIC_THRESHOLD = 0.95e18; // for the classic-market comparison

    uint256 public nextPositionId = 1;
    mapping(uint256 => Position) public positions;
    mapping(uint256 => uint256) public lastLiquidatedRound; // highest round a step used for this position
    mapping(uint256 => uint256) public lastAttemptRound; // highest round ANY attempt used (success or fail)

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
    event Liquidated(uint256 indexed id, uint256 roundId, uint256 debtRepaid, uint256 collateralSold, uint256 fee);
    event BadDebt(uint256 indexed id, uint256 amount);
    event SurplusWithdrawn(address indexed who, uint256 amount);

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

    function setParams(uint256 lt, uint256 target, uint256 maxFailedBill) external onlyOwner {
        liqThreshold = lt;
        targetHf = target;
        maxFailedGasBill = maxFailedBill;
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

        // settle-before-swap: move collateral to the venue first, then swap. The venue (and through it
        // the hook and router) prices against the cited round, not the latest round (M2).
        venue.setRoundPrice(price);
        collateralToken.transfer(address(venue), step.collateralToSell);
        uint256 got = venue.sellCollateral(step.collateralToSell, minOut);

        // Apply results. All proceeds go to the debt first, up to what is owed (H3).
        uint256 cleared = got < pos.debt ? got : pos.debt;
        pos.collateral -= step.collateralToSell;
        pos.debt -= cleared;
        totalCollateral -= step.collateralToSell;
        totalDebt -= cleared;
        totalSoldOut += step.collateralToSell;
        pos.liquidations += 1;
        if (roundId > lastLiquidatedRound[positionId]) lastLiquidatedRound[positionId] = roundId;
        if (roundId > lastAttemptRound[positionId]) lastAttemptRound[positionId] = roundId;

        // Surplus proceeds above the debt belong to the borrower, credited to a withdrawable balance (H3).
        uint256 surplus = got - cleared;
        if (surplus > 0) {
            withdrawableOf[pos.owner] += surplus;
            totalWithdrawable += surplus;
        }

        // Bad debt (H3): if the step sold the whole position but the proceeds could not cover the debt,
        // write the shortfall off against depositors and clear it from the position.
        if (step.insolvent && pos.collateral == 0 && pos.debt > 0) {
            badDebt += pos.debt;
            totalDebt -= pos.debt;
            emit BadDebt(positionId, pos.debt);
            pos.debt = 0;
        }

        // Bill the gas fee in collateral (WETH), capped at MAX_COST and FEE_CAP_BPS of the sale, unwrap
        // it and send the ETH to the self-paying account. No separate USDC tank (H2).
        uint256 feeCapByBps = step.collateralToSell * FEE_CAP_BPS / 10_000;
        feeBilled = _billFeeFromCollateral(positionId, _min(cap, feeCapByBps));

        debtRepaid = cleared;
        collateralSold = step.collateralToSell;
        _setActive(false);
        emit Liquidated(positionId, roundId, cleared, step.collateralToSell, feeBilled);
    }

    /// @notice Bill a failed attempt in collateral, capped at MAX_COST and MAX_FAILED_GAS_BILL, and
    ///         record the attempt's round so the same round cannot be retried (one failure per round).
    function billFailedAttempt(uint256 positionId, uint256 roundId, uint256 cap) external {
        if (msg.sender != account) revert NotAccount();
        if (roundId > lastAttemptRound[positionId]) lastAttemptRound[positionId] = roundId;
        _billFeeFromCollateral(positionId, _min(cap, maxFailedGasBill));
    }

    /// @notice Withdraw liquidation surplus credited to the caller.
    function withdrawSurplus(uint256 amount) external {
        uint256 bal = withdrawableOf[msg.sender];
        if (amount > bal) amount = bal;
        withdrawableOf[msg.sender] = bal - amount;
        totalWithdrawable -= amount;
        debtToken.transfer(msg.sender, amount);
    }

    /// @dev Take `want` WETH collateral from the position (never more than it holds), unwrap it, and send
    ///      the ETH to the account. Returns the amount actually billed. This is the only path that moves
    ///      a position's collateral into gas, so the borrower is never billed more than `want` <= cap.
    function _billFeeFromCollateral(uint256 positionId, uint256 want) internal returns (uint256 fee) {
        Position storage pos = positions[positionId];
        fee = want < pos.collateral ? want : pos.collateral;
        if (fee == 0) return 0;
        pos.collateral -= fee;
        totalCollateral -= fee;
        totalFeeBilled += fee;
        IWETH(address(collateralToken)).withdraw(fee);
        (bool ok,) = account.call{value: fee}("");
        require(ok, "gas transfer failed");
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    receive() external payable {}

    // --- views ---

    /// @notice Health factor using a specific round's VERIFY price (reverts if the round is unusable).
    function healthFactorAtRound(uint256 id, uint256 roundId) external view returns (uint256) {
        uint256 price = feed.checkRoundForVerify(roundId);
        Position storage pos = positions[id];
        return LiquidationMath.healthFactor(pos.collateral, price, liqThreshold, pos.debt);
    }

    function healthFactor(uint256 id) external view returns (uint256) {
        return _hf(positions[id]);
    }

    function liquidationCount(uint256 id) external view returns (uint256) {
        return positions[id].liquidations;
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
