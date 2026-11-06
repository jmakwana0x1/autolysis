import { parseAbi } from "viem";

export const accountAbi = parseAbi([
  "function owner() view returns (address)",
  "function market() view returns (address)",
  "function env() view returns (address)",
  "function feeCapTotal() view returns (uint256)",
  "function setFeeCap(uint256)",
  "function storageOnlyVerify() view returns (bool)",
  "function setStorageOnlyVerify(bool)",
  "function stakingRegistry() view returns (address)",
  "function setStakingRegistry(address)",
  "function stake(uint32) payable",
  "function pushVerifySnapshot(uint256,uint256)",
  "event LiquidationOk(uint256 indexed positionId, uint256 debtRepaid, uint256 collateralSold, uint256 fee)",
  "event LiquidationFailed(uint256 indexed positionId, uint256 fee)",
]);

export const registryAbi = parseAbi([
  "function getDepositInfo(address) view returns (uint256 stake, uint32 unstakeDelaySec, uint64 withdrawTime)",
]);

export const marketAbi = parseAbi([
  "function nextPositionId() view returns (uint256)",
  "function open() returns (uint256)",
  "function deposit(uint256,uint256)",
  "function borrow(uint256,uint256)",
  "function positions(uint256) view returns (address owner, uint256 collateral, uint256 debt, uint256 liquidations)",
  "function healthFactor(uint256) view returns (uint256)",
  "function liquidationCount(uint256) view returns (uint256)",
  "function lastAttemptRound(uint256) view returns (uint256)",
  "function totalFeeBilled() view returns (uint256)",
]);

export const feedAbi = parseAbi([
  "function latestRound() view returns (uint256)",
  "function getRound(uint256) view returns ((uint256 price, uint256 timestamp, bool valid))",
  "function post(uint256) returns (uint256)",
]);

export const erc20Abi = parseAbi([
  "function mint(address,uint256)",
  "function approve(address,uint256) returns (bool)",
  "function balanceOf(address) view returns (uint256)",
]);

export const wethAbi = parseAbi([
  "function deposit() payable",
  "function approve(address,uint256) returns (bool)",
  "function balanceOf(address) view returns (uint256)",
]);

export const hookAbi = parseAbi([
  "function deposit(address,uint256)",
  "function depositsOf(address) view returns (uint256)",
]);
