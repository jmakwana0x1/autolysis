// Frame-transaction builders for Autolysis liquidations, on the real hegota-support encoder (EIP-8141 /
// EIP-8250, the ethrex eip8141-tracer profile). No hand-rolled serialization: build with newTx/frame,
// encode with encodeTx, submit with eth_sendFrameTransaction(toWire(tx)). There is no expiry field;
// freshness is the round window.
import { type Address, type Hex, encodeFunctionData, keccak256, encodeAbiParameters } from "viem";
import { profile } from "@forshtat/hegota-support/profiles/ethrex-eip8141-tracer";
import { newTx, frame, encodeTx, sigScheme, type FrameTx, type SignatureEntry } from "@forshtat/hegota-support/tx";
import { readProbes } from "./registry.js";

export { profile };
export const SELFLIQ_SELECTOR = "0xf3ab9cad"; // selfLiquidate(uint256,uint256)
export const VERIFY_SELECTOR = "0x3ad51b8d"; // verifyLiquidation()

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

/** Signature entries for the liquidation. The pitch is "no signature": an empty list. ERC-8421 rejects
 *  any INVALID signature, so if the devnet rejects an empty list the probe falls back to a single
 *  ARBITRARY entry (scheme 0x0, empty fields); `probes.json.signatureForm` records which the devnet
 *  accepts, and the builder uses it (defaulting to empty until probed). */
export type SignatureForm = "empty" | "arbitrary";
export function signatureEntries(form?: SignatureForm): SignatureEntry[] {
  const f = form ?? ((readProbes().signatureForm as SignatureForm) ?? "empty");
  if (f === "arbitrary") {
    return [{ scheme: sigScheme(profile, "ARBITRARY"), signer: "0x", msg: "0x", signature: "0x" }];
  }
  return [];
}

/** key = H(market, id) with the top byte cleared — must match FirewallRules.nonceKey. */
export function nonceKeyFor(market: Address, positionId: bigint): bigint {
  const h = BigInt(keccak256(encodeAbiParameters([{ type: "address" }, { type: "uint256" }], [market, positionId])));
  return h & ((1n << 248n) - 1n);
}

export type CanonicalParams = {
  chainId: number;
  account: Address;
  market: Address;
  positionId: bigint;
  roundId: bigint;
  sequence: bigint; // the key's current on-chain nonce (read from the devnet), NOT the liquidation count (C2)
  maxFeePerGas: bigint;
  maxPriorityFeePerGas?: bigint;
  verifyGas: bigint;
  verifyStateLimit: bigint;
  executeGas: bigint;
  signatureForm?: SignatureForm;
};

/** The one transaction shape the firewall approves for (position, step). */
export function canonicalLiquidationTx(p: CanonicalParams): FrameTx {
  return newTx({
    chainId: p.chainId,
    sender: p.account,
    nonceSeq: p.sequence,
    nonceKeys: [nonceKeyFor(p.market, p.positionId)],
    fees: { maxFeePerGas: p.maxFeePerGas, maxPriorityFeePerGas: p.maxPriorityFeePerGas ?? p.maxFeePerGas },
    signatures: signatureEntries(p.signatureForm),
    frames: [
      frame(profile, "VERIFY", {
        scope: "EXECUTION_AND_PAYMENT",
        execution: p.verifyGas,
        state: p.verifyStateLimit,
        data: encodeFunctionData({ abi: accountAbi, functionName: "verifyLiquidation" }),
      }),
      frame(profile, "SENDER", {
        execution: p.executeGas,
        data: encodeFunctionData({ abi: accountAbi, functionName: "selfLiquidate", args: [p.positionId, p.roundId] }),
      }),
    ],
  });
}

export const encodeFrameTx = (tx: FrameTx): Hex => encodeTx(profile, tx);
export type { FrameTx };
