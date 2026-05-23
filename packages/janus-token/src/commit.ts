/**
 * commit.ts — Off-chain Pedersen commitment computation
 *
 * Uses circomlibjs buildPedersenHash implementing the circomlib Pedersen(192) template:
 *   64-bit value || 128-bit blinding, packed as little-endian bytes.
 *
 * The resulting BabyJubJub point (x, y) matches what JanusToken.sol stores on-chain.
 * Commitment is a hiding and binding commitment:
 *   C = Pedersen(value_bits[0..63] || blinding_bits[0..127])
 *
 * Field prime P = 21888242871839275222246405745257275088548364400416034343698204186575808495617
 */

import { buildPedersenHash, buildBabyjub } from "circomlibjs";
import type { CommitmentPoint } from "./types";

// Cache circomlibjs instances (WASM init is expensive)
let _pedersenHash: Awaited<ReturnType<typeof buildPedersenHash>> | null = null;
let _babyJub: Awaited<ReturnType<typeof buildBabyjub>> | null = null;

async function getPedersenHash() {
  if (!_pedersenHash) _pedersenHash = await buildPedersenHash();
  return _pedersenHash;
}

async function getBabyJub() {
  if (!_babyJub) _babyJub = await buildBabyjub();
  return _babyJub;
}

/**
 * Compute a BabyJubJub Pedersen commitment.
 *
 * Matches the circomlib Pedersen(192) template used in the v2 circuit:
 *   - value:    64 bits, little-endian bytes [0..7]
 *   - blinding: 128 bits, little-endian bytes [8..23]
 *
 * @param value    64-bit token amount (must be < 2^64)
 * @param blinding 128-bit blinding factor (must be < 2^128, should be random)
 * @returns BabyJubJub point (x, y) as bigints
 */
export async function computeCommitment(
  value: bigint,
  blinding: bigint
): Promise<CommitmentPoint> {
  if (value < 0n || value >= (1n << 64n)) {
    throw new Error(`computeCommitment: value must be in [0, 2^64), got ${value}`);
  }
  if (blinding < 0n || blinding >= (1n << 128n)) {
    throw new Error(`computeCommitment: blinding must be in [0, 2^128), got ${blinding}`);
  }

  const pedersenHash = await getPedersenHash();
  const babyJub = await getBabyJub();
  const F = babyJub.F;

  // Pack as 24-byte little-endian buffer
  const buf = Buffer.alloc(24, 0);

  let v = value;
  for (let i = 0; i < 8; i++) {
    buf[i] = Number(v & 0xffn);
    v >>= 8n;
  }

  let b = blinding;
  for (let i = 8; i < 24; i++) {
    buf[i] = Number(b & 0xffn);
    b >>= 8n;
  }

  const hash = pedersenHash.hash(buf);
  const point = babyJub.unpackPoint(hash);

  return {
    x: F.toObject(point[0]) as bigint,
    y: F.toObject(point[1]) as bigint,
  };
}

/**
 * Add two commitments homomorphically on BabyJubJub.
 * addCommitments(Pedersen(a, r1), Pedersen(b, r2)) = Pedersen(a+b, r1+r2)
 */
export async function addCommitments(
  a: CommitmentPoint,
  b: CommitmentPoint
): Promise<CommitmentPoint> {
  const babyJub = await getBabyJub();
  const F = babyJub.F;

  const ptA = [F.e(a.x), F.e(a.y)];
  const ptB = [F.e(b.x), F.e(b.y)];

  const result = babyJub.addPoint(ptA, ptB);
  return {
    x: F.toObject(result[0]) as bigint,
    y: F.toObject(result[1]) as bigint,
  };
}

/**
 * Negate a commitment: negate((x, y)) = (P - x, y)
 */
export async function negateCommitment(
  point: CommitmentPoint
): Promise<CommitmentPoint> {
  const P = BigInt(
    "21888242871839275222246405745257275088548364400416034343698204186575808495617"
  );
  return {
    x: point.x === 0n ? 0n : P - point.x,
    y: point.y,
  };
}

/**
 * Decrypt a balance from a commitment by brute-force search up to maxValue.
 * ONLY for testing — O(maxValue) operations.
 * Production apps should use the blinding factor they stored at mint time.
 *
 * @param commit    On-chain commitment (x, y)
 * @param blinding  Known blinding factor
 * @param maxValue  Maximum value to search (default: 10000)
 */
export async function decryptBalance(
  commit: CommitmentPoint,
  blinding: bigint,
  maxValue = 10000n
): Promise<bigint | null> {
  for (let v = 0n; v <= maxValue; v++) {
    const candidate = await computeCommitment(v, blinding);
    if (candidate.x === commit.x && candidate.y === commit.y) {
      return v;
    }
  }
  return null;
}
