// realFrameIO.sendFrame's transport retry: never a second send when the sidecar already holds the tx.
import { describe, it, expect, vi, afterEach } from "vitest";
import { realFrameIO } from "../src/gateA/io.js";
import { canonicalLiquidationTx } from "../src/frameTx.js";

const tx = canonicalLiquidationTx({
  chainId: 1337, account: "0x00000000000000000000000000000000000000a5", market: "0x00000000000000000000000000000000000000a6",
  positionId: 3n, roundId: 4n, sequence: 0n, maxFeePerGas: 2_000_000_000n, verifyGas: 99_900n, verifyStateLimit: 147_920n,
  executeGas: 1_500_000n, executeStateLimit: 500_000n, signatureForm: "arbitrary",
});
const io = realFrameIO({ rpcUrl: "http://gw", ethrexUrl: "http://ethrex", frameUrl: "http://miner", privateKey: "0x01", legacyGasPriceWei: 1n });
const reply = (body: unknown) => new Response(JSON.stringify({ jsonrpc: "2.0", id: 1, ...body as object }));

function stub(script: (method: string) => Response | Error) {
  const calls: string[] = [];
  vi.stubGlobal("fetch", async (_url: string, init: { body: string }) => {
    const m = JSON.parse(init.body).method;
    calls.push(m);
    const r = script(m);
    if (r instanceof Error) throw r;
    return r;
  });
  return calls;
}

afterEach(() => vi.unstubAllGlobals());

describe("sendFrame transport retry", () => {
  it("does not resend when the sidecar already holds the tx", async () => {
    let n = 0;
    const calls = stub((m) => (m === "eth_sendFrameTransaction" ? (n++ === 0 ? new TypeError("fetch failed") : reply({ result: "0xdup" })) : reply({ result: { status: "New" } })));
    const h = await io.sendFrame(tx);
    expect(calls.filter((c) => c === "eth_sendFrameTransaction")).toHaveLength(1);
    expect(h).toMatch(/^0x[0-9a-f]{64}$/);
  }, 10_000);

  it("resends the identical tx once when the sidecar never received it", async () => {
    let n = 0;
    const calls = stub((m) =>
      m === "eth_sendFrameTransaction" ? (n++ === 0 ? new TypeError("fetch failed") : reply({ result: "0xabc" })) : reply({ error: { code: -32600, message: "Frame transaction not found" } }),
    );
    expect(await io.sendFrame(tx)).toBe("0xabc");
    expect(calls.filter((c) => c === "eth_sendFrameTransaction")).toHaveLength(2);
  }, 10_000);

  it("reports both transport failures and the hash when the retry also fails", async () => {
    stub((m) => (m === "eth_sendFrameTransaction" ? new TypeError("fetch failed") : reply({ error: { message: "Frame transaction not found" } })));
    await expect(io.sendFrame(tx)).rejects.toThrow(/transport failure twice .* not known to the sidecar/);
  }, 10_000);
});
