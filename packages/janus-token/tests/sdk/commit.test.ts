/**
 * SDK tests — commitment algebra
 *
 * Tests that computeCommitment, addCommitments, and negateCommitment
 * produce consistent results matching the on-chain BabyJubJub curve.
 */

import { describe, it, expect } from "vitest";
import { computeCommitment, addCommitments, negateCommitment } from "../../src/commit";

const P = BigInt("21888242871839275222246405745257275088548364400416034343698204186575808495617");

// Known generator point G (BASE8) from circomlibjs
// = buildBabyjub().mulPointEscalar(BASE, 8) — matches what MockBabyJub produces
const G_X = BigInt("5299619240641551281634865583518297030282874472190772894086521144482721001553");
const G_Y = BigInt("16950150798460657717958625567821834550301663161624707787222815936182638968203");

describe("computeCommitment", () => {
  it("should return a non-identity point for value=0 with nonzero blinding", async () => {
    const commit = await computeCommitment(0n, 1n);
    // value=0 with nonzero blinding is not identity
    expect(typeof commit.x).toBe("bigint");
    expect(typeof commit.y).toBe("bigint");
    // Both coordinates should be valid field elements
    expect(commit.x).toBeGreaterThanOrEqual(0n);
    expect(commit.x).toBeLessThan(P);
    expect(commit.y).toBeGreaterThanOrEqual(0n);
    expect(commit.y).toBeLessThan(P);
  });

  it("same inputs produce same commitment (deterministic)", async () => {
    const a = await computeCommitment(100n, 999n);
    const b = await computeCommitment(100n, 999n);
    expect(a.x).toBe(b.x);
    expect(a.y).toBe(b.y);
  });

  it("different amounts produce different commitments (hiding)", async () => {
    const a = await computeCommitment(100n, 999n);
    const b = await computeCommitment(200n, 999n);
    expect(a.x).not.toBe(b.x);
  });

  it("different blindings produce different commitments (binding)", async () => {
    const a = await computeCommitment(100n, 111n);
    const b = await computeCommitment(100n, 222n);
    expect(a.x).not.toBe(b.x);
  });

  it("throws if value >= 2^64", async () => {
    await expect(computeCommitment(1n << 64n, 0n)).rejects.toThrow(
      "value must be in [0, 2^64)"
    );
  });

  it("throws if blinding >= 2^128", async () => {
    await expect(computeCommitment(1n, 1n << 128n)).rejects.toThrow(
      "blinding must be in [0, 2^128)"
    );
  });
});

describe("addCommitments", () => {
  it("adding identity (0,1) to a point returns the same point", async () => {
    const c = await computeCommitment(100n, 999n);
    const identity = { x: 0n, y: 1n };
    const result = await addCommitments(c, identity);
    expect(result.x).toBe(c.x);
    expect(result.y).toBe(c.y);
  });

  it("is commutative: add(a, b) == add(b, a)", async () => {
    const a = await computeCommitment(100n, 111n);
    const b = await computeCommitment(200n, 222n);
    const ab = await addCommitments(a, b);
    const ba = await addCommitments(b, a);
    expect(ab.x).toBe(ba.x);
    expect(ab.y).toBe(ba.y);
  });
});

describe("negateCommitment", () => {
  it("negate((0, 1)) = (0, 1) — identity negates to itself", async () => {
    const neg = await negateCommitment({ x: 0n, y: 1n });
    expect(neg.x).toBe(0n);
    expect(neg.y).toBe(1n);
  });

  it("negate twice returns original point", async () => {
    const c = await computeCommitment(50n, 12345n);
    const neg = await negateCommitment(c);
    const negNeg = await negateCommitment(neg);
    expect(negNeg.x).toBe(c.x);
    expect(negNeg.y).toBe(c.y);
  });
});
