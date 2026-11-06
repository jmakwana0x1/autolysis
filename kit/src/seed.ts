// `just reset` seed: populate a fresh deployment with borrowers, depositor liquidity, house deposits and
// makers so the demo and scenes have state. Reads addresses from deployments/<chainId>.json. The
// account's stake (R2) is applied only when a staking registry address is present (devnet); on a local
// anvil with frame features off it is skipped with a note.
import { createWalletClient, createPublicClient, defineChain, http, parseEther, getContract, type Address } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { ROOT } from "./registry.js";

const RPC = process.env.RPC_URL ?? "http://127.0.0.1:8545";
// anvil's well-known keys (deployer + 3 borrowers + 2 makers + 1 depositor steward).
const KEYS = [
  "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80",
  "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d",
  "0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a",
  "0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6",
  "0x47e179ec197488593b187f80a00eb0da91f1b9d0b13f8733639f19c30a34926a",
  "0x8b3a350cf5c34c9194ca85829a2df0ec3153be0318b5e2d3348e872092edffba",
] as const;

const erc20 = [
  { type: "function", name: "mint", inputs: [{ type: "address" }, { type: "uint256" }], outputs: [], stateMutability: "nonpayable" },
  { type: "function", name: "approve", inputs: [{ type: "address" }, { type: "uint256" }], outputs: [{ type: "bool" }], stateMutability: "nonpayable" },
] as const;
const marketAbi = [
  { type: "function", name: "open", inputs: [], outputs: [{ type: "uint256" }], stateMutability: "nonpayable" },
  { type: "function", name: "deposit", inputs: [{ type: "uint256" }, { type: "uint256" }], outputs: [], stateMutability: "nonpayable" },
  { type: "function", name: "borrow", inputs: [{ type: "uint256" }, { type: "uint256" }], outputs: [], stateMutability: "nonpayable" },
  { type: "function", name: "healthFactor", inputs: [{ type: "uint256" }], outputs: [{ type: "uint256" }], stateMutability: "view" },
] as const;

async function main() {
  const pub = createPublicClient({ transport: http(RPC) });
  const chainId = await pub.getChainId();
  const chain = defineChain({ id: chainId, name: "local", nativeCurrency: { name: "ETH", symbol: "ETH", decimals: 18 }, rpcUrls: { default: { http: [RPC] } } });
  const d: Record<string, Address> = JSON.parse(readFileSync(join(ROOT, "deployments", `${chainId}.addresses.json`), "utf8"));
  const deployer = privateKeyToAccount(KEYS[0]);
  const w = (k: `0x${string}`) => createWalletClient({ account: privateKeyToAccount(k), chain, transport: http(RPC) });

  const weth = (acct: ReturnType<typeof w>) => getContract({ address: d.WETH, abi: erc20, client: acct });
  const usdc = (acct: ReturnType<typeof w>) => getContract({ address: d.USDC, abi: erc20, client: acct });
  const market = (acct: ReturnType<typeof w>) => getContract({ address: d.AutolysisMarket, abi: marketAbi, client: acct });

  const dep = w(KEYS[0]);
  // Depositor liquidity: USDC the market can lend.
  await usdc(dep).write.mint([d.AutolysisMarket, parseEther("2000000")]);
  // House deposits tier (owner funds the hook).
  await usdc(dep).write.mint([deployer.address, parseEther("200000")]);

  // 3 borrowers at HF ~1.03 / 1.06 / 1.10 (collateral 100 WETH @2, L=0.8 => maxDebt 160).
  const targets = [103n, 106n, 110n];
  for (let i = 0; i < 3; i++) {
    const b = w(KEYS[1 + i]);
    const col = parseEther("100");
    await weth(b).write.mint([privateKeyToAccount(KEYS[1 + i]).address, col]);
    await weth(b).write.approve([d.AutolysisMarket, 2n ** 256n - 1n]);
    const hash = await market(b).write.open();
    await pub.waitForTransactionReceipt({ hash });
    const posId = BigInt(i + 1);
    await market(b).write.deposit([posId, col]);
    const maxDebt = (160n * parseEther("1")) ; // 100*2*0.8
    const debt = (maxDebt * 100n) / targets[i];
    await market(b).write.borrow([posId, debt]);
    const hf = await pub.readContract({ address: d.AutolysisMarket, abi: marketAbi, functionName: "healthFactor", args: [posId] });
    console.log(`borrower ${i + 1}: posId ${posId}, HF ${(Number(hf) / 1e18).toFixed(3)}`);
  }

  // 2 makers: fund their wallets with USDC (the MakerFactory wiring / registration is done by the demo
  // script or the hook owner; here we just fund and note it).
  for (let i = 0; i < 2; i++) {
    const m = privateKeyToAccount(KEYS[4 + i]).address;
    await usdc(dep).write.mint([m, parseEther("500000")]);
    console.log(`maker ${i + 1} funded: ${m}`);
  }

  if (d.StakingRegistry) {
    console.log("staking registry present; stake the account via AutolysisAccount.stake (R2)");
  } else {
    console.log("no StakingRegistry in deployments: stake skipped (local anvil / frame features off)");
  }
  console.log("seed complete");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
