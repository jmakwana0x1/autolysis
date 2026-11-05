// Frame transaction codec (EIP-8141 / EIP-8250, keyed nonces, per-frame allowed scope). There is NO
// expiry field (TXPARAM 0x07 is BLOB_COUNT); freshness comes from the round window. NOTE: for the live
// devnet this hand-rolled encoding is superseded by the hegota-support package (newTx/frame/encodeTx +
// eth_sendFrameTransaction); kept here for the local carrier/attack unit tests (C5e pending).
// The field order follows the sidecar draft and is checked by the probes; if the probes disagree,
// fix this file and the matching Solidity mock together ("mock and reality agree").
import {
  type Address,
  type Hex,
  concatHex,
  encodeAbiParameters,
  encodeFunctionData,
  keccak256,
  numberToHex,
  toRlp,
} from "viem";

export const FRAME_TX_TYPE = 0x06;
export const MODE = { DEFAULT: 0, VERIFY: 1, SENDER: 2 } as const;
export const SCOPE = { NONE: 0, PAYMENT: 1, EXECUTION: 2, EXECUTION_AND_PAYMENT: 3 } as const;

export type Frame = { mode: number; target: Address; gasLimit: bigint; stateLimit: bigint; value: bigint; allowedScope: number; data: Hex };

export type FrameTx = {
  chainId: number;
  sender: Address;
  nonceKeys: bigint[];
  sequence: bigint; // the key's current on-chain nonce (read from the devnet), NOT the liquidation count (C2)
  maxPriorityFeePerGas: bigint;
  maxFeePerGas: bigint;
  frames: Frame[];
};

const q = (v: bigint | number): Hex => (BigInt(v) === 0n ? "0x" : numberToHex(v));

export function serializeFrameTx(tx: FrameTx): Hex {
  const body = toRlp([
    q(tx.chainId),
    tx.sender,
    tx.nonceKeys.map(q),
    q(tx.sequence),
    q(tx.maxPriorityFeePerGas),
    q(tx.maxFeePerGas),
    tx.frames.map((f) => [q(f.mode), f.target, q(f.gasLimit), q(f.stateLimit), q(f.value), q(f.allowedScope), f.data]),
  ]);
  return concatHex([numberToHex(FRAME_TX_TYPE, { size: 1 }), body]);
}

/** key = H(market, id) with the top byte cleared — must match FirewallRules.nonceKey. */
export function nonceKeyFor(market: Address, positionId: bigint): bigint {
  const h = BigInt(keccak256(encodeAbiParameters([{ type: "address" }, { type: "uint256" }], [market, positionId])));
  return h & ((1n << 248n) - 1n);
}

export const accountAbi = [
  { type: "function", name: "verifyLiquidation", inputs: [], outputs: [], stateMutability: "nonpayable" },
  {
    type: "function",
    name: "selfLiquidate",
    inputs: [
      { name: "positionId", type: "uint256" },
      { name: "roundId", type: "uint256" },
    ],
    outputs: [],
    stateMutability: "nonpayable",
  },
] as const;

export type CanonicalParams = {
  chainId: number;
  account: Address;
  market: Address;
  positionId: bigint;
  roundId: bigint;
  sequence: bigint;
  maxFeePerGas: bigint;
  maxPriorityFeePerGas: bigint;
  verifyGas: bigint;
  verifyStateLimit: bigint;
  executeGas: bigint;
};

/** The one transaction shape the firewall approves for (position, step). */
export function canonicalLiquidationTx(p: CanonicalParams): FrameTx {
  return {
    chainId: p.chainId,
    sender: p.account,
    nonceKeys: [nonceKeyFor(p.market, p.positionId)],
    sequence: p.sequence,
    maxPriorityFeePerGas: p.maxPriorityFeePerGas,
    maxFeePerGas: p.maxFeePerGas,
    frames: [
      {
        mode: MODE.VERIFY,
        target: p.account,
        gasLimit: p.verifyGas,
        stateLimit: p.verifyStateLimit,
        value: 0n,
        allowedScope: SCOPE.EXECUTION_AND_PAYMENT,
        data: encodeFunctionData({ abi: accountAbi, functionName: "verifyLiquidation" }),
      },
      {
        mode: MODE.SENDER,
        target: p.account,
        gasLimit: p.executeGas,
        stateLimit: 0n,
        value: 0n,
        allowedScope: SCOPE.NONE,
        data: encodeFunctionData({ abi: accountAbi, functionName: "selfLiquidate", args: [p.positionId, p.roundId] }),
      },
    ],
  };
}

/** Total gas the fee cap applies to (all frames). */
export const totalGas = (tx: FrameTx) => tx.frames.reduce((s, f) => s + f.gasLimit, 0n);
