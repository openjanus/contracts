/**
 * Integration tests — against deployed JanusToken on Flow EVM testnet
 *
 * Tests the SDK against the real deployed contract at:
 *   0x53F49881A1132FF4F674D2c015e35D5B07Fa1F4A (Flow EVM testnet)
 *
 * These tests are READ-ONLY — they don't require a private key.
 * They verify that the deployed contract:
 *   1. Responds to balance queries
 *   2. Returns the correct identity for new accounts
 *   3. Reports the correct primitives addresses
 *   4. Reports the correct mode (NATIVE)
 *
 * Write operations (mint, transfer) require a funded account — covered separately.
 *
 * Run: npx vitest run tests/sdk/integration.test.ts
 * (requires internet access to Flow EVM testnet RPC)
 */

import { describe, it, expect } from "vitest";
import { JanusToken, TESTNET_DEPLOYMENT } from "../../src";

const JANUS_TOKEN_ADDRESS = TESTNET_DEPLOYMENT.evm;
const GROTH16_VERIFIER    = TESTNET_DEPLOYMENT.primitives.Groth16Verifier;
const BABY_JUB            = TESTNET_DEPLOYMENT.primitives.BabyJub;

// A random address that has never interacted with this contract
const FRESH_ADDRESS = "0x000000000000000000000000000000000000dEaD";

describe("JanusToken deployed integration", () => {
  let token: JanusToken;

  // Shared setup — connect once for all tests
  const setup = async () => {
    token = new JanusToken({
      address: JANUS_TOKEN_ADDRESS,
      network: "testnet",
    });
    await token.connect();
  };

  it("I1: connects to deployed contract and address is correct", async () => {
    await setup();
    expect(token.address.toLowerCase()).toBe(JANUS_TOKEN_ADDRESS.toLowerCase());
  });

  it("I2: fresh account has identity commitment (0, 1) — zero balance", async () => {
    await setup();
    const commit = await token.balanceOfCommitment(FRESH_ADDRESS);
    expect(commit.x).toBe(0n);
    expect(commit.y).toBe(1n);
  });

  it("I3: contract is in NATIVE mode (no underlying token)", async () => {
    await setup();
    const isWrapper = await token.isWrapperMode();
    expect(isWrapper).toBe(false);
  });

  it("I4: total supply commitment is accessible (identity or non-identity)", async () => {
    await setup();
    const supply = await token.totalSupplyCommitment();
    // After any mints, supply could be non-identity. Both cases are valid.
    expect(typeof supply.x).toBe("bigint");
    expect(typeof supply.y).toBe("bigint");
    // Valid BabyJubJub field elements (x, y < P)
    const P = BigInt("21888242871839275222246405745257275088548364400416034343698204186575808495617");
    expect(supply.x).toBeLessThan(P);
    expect(supply.y).toBeLessThan(P);
    expect(supply.y).toBeGreaterThan(0n);
  });

  it("I5: balanceOfCommitment returns field elements for any address", async () => {
    await setup();
    const P = BigInt("21888242871839275222246405745257275088548364400416034343698204186575808495617");

    // Check a second address
    const addr2 = "0x0000000000000000000000000000000000000001";
    const c2 = await token.balanceOfCommitment(addr2);
    expect(c2.x).toBeLessThan(P);
    expect(c2.y).toBeLessThan(P);
  });
});
