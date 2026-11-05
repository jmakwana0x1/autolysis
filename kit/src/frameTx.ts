// Frame transaction codec for the devnet sidecar draft (EIP-8141 lineage, with keyed nonces and expiry).
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

export type Frame = { mode: number; target: Address; gasLimit: bigint; stateLimit: bigint; value: bigint; data: Hex };

export type FrameTx = {
  chainId: number;
  sender: Address;
  nonceKeys: bigint[];
  sequence: bigint; // the key's current on-chain nonce (read from the devnet), NOT the liquidation count (C2)
  maxPriorityFeePerGas: bigint;
  maxFeePerGas: bigint;
  expiry: bigint;
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
    q(tx.expiry),
    tx.frames.map((f) => [q(f.mode), f.target, q(f.gasLimit), q(f.stateLimit), q(f.value), f.data]),
  ]);
  return concatHex([numberToHex(FRAME_TX_TYPE, { size: 1 }), body]);
}

/** key = H(market, id) with the top byte cleared — must match FirewallRules.nonceKey. */
export function nonceKeyFor(market: Address, positionId: bigint): bigint {
  const h = BigInt(keccak256(encodeAbiParameters([{ type: "address" }, { type: "uint256" }], [market, positionId])));
  return h & ((1n << 248n) - 1n);
}

export const accountAbi = [
  { type: "function", name: "verify", inputs: [], outputs: [], stateMutability: "nonpayable" },
  {
    type: "function",
    name: "execute",
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
  expiry: bigint;
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
    expiry: p.expiry,
    frames: [
      {
        mode: MODE.VERIFY,
        target: p.account,
        gasLimit: p.verifyGas,
        stateLimit: p.verifyStateLimit,
        value: 0n,
        data: encodeFunctionData({ abi: accountAbi, functionName: "verify" }),
      },
      {
        mode: MODE.SENDER,
        target: p.account,
        gasLimit: p.executeGas,
        stateLimit: 0n,
        value: 0n,
        data: encodeFunctionData({ abi: accountAbi, functionName: "execute", args: [p.positionId, p.roundId] }),
      },
    ],
  };
}

/** Total gas the fee cap applies to (all frames). */
export const totalGas = (tx: FrameTx) => tx.frames.reduce((s, f) => s + f.gasLimit, 0n);
