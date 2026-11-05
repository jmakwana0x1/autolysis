// Devnet scenes (Phase 2, extended in 3-4). Each runs against a live devnet + sidecar and asserts the
// outcome in the plan's adversarial table. They need RPC_URL and a deployment, so in this build they
// throw a clear "requires devnet" error. Every scene has a matching Foundry mock test under
// test/scenarios/ that runs locally ("mock and reality agree") -- named in each entry.
const NEEDS_DEVNET = (scene: string, mockTest: string) => {
  throw new Error(`scene "${scene}" requires RPC_URL + a devnet deployment; local equivalent: ${mockTest}`);
};

export const scenes: Record<string, () => Promise<void>> = {
  // Borrower repays in the same block; the pending liquidation becomes invalid and is dropped (no fee).
  async rescue() {
    NEEDS_DEVNET("rescue", "test/scenarios/Adversarial.t.sol::test_rescueInvalidatesPending");
  },
  // Three gradual steps wind the position back to health; HF never falls.
  async gradualThreeStep() {
    NEEDS_DEVNET("gradualThreeStep", "test/scenarios/Adversarial.t.sol::test_gradualThreeStepSale");
  },
  // Oracle crash: canonical mempool includes 0 liquidations, the alternative mempool includes 12.
  async crash() {
    NEEDS_DEVNET("crash", "test/scenarios/Adversarial.t.sol (gradual sale + never-revert envelope)");
  },
  // A same-key rebroadcast with a 10% higher fee replaces the pending tx; reputation stays flat.
  async replacementKeepsReputationFlat() {
    NEEDS_DEVNET("replacementKeepsReputationFlat", "kit/test/carrier.test.ts (replacement reuses the slot)");
  },
  // Every attack from the adversarial table is rejected by VERIFY / the feed.
  async everyAttackRejected() {
    NEEDS_DEVNET(
      "everyAttackRejected",
      "test/fuzz/FirewallRules.t.sol + test/scenarios/Adversarial.t.sol (key-append, fake round, fee griefing)",
    );
  },
};
