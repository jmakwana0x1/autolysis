// Devnet scenes (Phase 2, extended in 3-4). These run against a live devnet + sidecar; without an
// RPC they are not exercised (the kit's unit tests cover the pure pieces). Each scene has a matching
// Foundry mock test under test/ ("mock and reality agree").
export const scenes: Record<string, () => Promise<void>> = {
  async rescue() {
    throw new Error("devnet scene: requires RPC_URL + deployed contracts (not wired in CI)");
  },
  async gradualThreeStep() {
    throw new Error("devnet scene: requires RPC_URL + deployed contracts (not wired in CI)");
  },
  async crash() {
    throw new Error("devnet scene: requires RPC_URL + deployed contracts (not wired in CI)");
  },
  async replacementKeepsReputationFlat() {
    throw new Error("devnet scene: requires RPC_URL + deployed contracts (not wired in CI)");
  },
};
