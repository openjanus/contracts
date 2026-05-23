/**
 * proof.ts — Off-chain Groth16 proof generation for JanusToken
 *
 * Generates proofs for JanusToken.confidentialTransfer using the
 * ConfidentialTransfer v2 circuit (snarkjs + groth16).
 *
 * EIP-197 pi_b Fp2 swap:
 *   snarkjs pi_b = [[b00, b01], [b10, b11]] (re, im per BN254)
 *   EVM ecPairing precompile requires (im, re): [[b01, b00], [b11, b10]]
 *   This function applies the swap automatically.
 */

import * as snarkjs from "snarkjs";
import { computeCommitment } from "./commit";
import type { TransferProofInput, TransferProofResult, CommitmentPoint } from "./types";

/**
 * Generate a Groth16 transfer proof for JanusToken.confidentialTransfer.
 *
 * @param input Transfer proof parameters
 * @returns Proof + public inputs ready for on-chain submission
 */
export async function generateTransferProof(
  input: TransferProofInput
): Promise<TransferProofResult> {
  const {
    oldBalance,
    oldBlinding,
    transferAmount,
    transferBlinding,
    newBlinding,
    wasmPath,
    zkeyPath,
    vkPath,
  } = input;

  // 1. Compute the three Pedersen commitments
  const oldCommit = await computeCommitment(oldBalance, oldBlinding);
  const transferCommit = await computeCommitment(transferAmount, transferBlinding);
  const newBalance = oldBalance - transferAmount;
  if (newBalance < 0n) {
    throw new Error(
      `generateTransferProof: transfer amount ${transferAmount} exceeds balance ${oldBalance}`
    );
  }
  const newCommit = await computeCommitment(newBalance, newBlinding);

  // 2. Build circuit input
  const circuitInput = {
    old_value: oldBalance.toString(),
    old_blinding: oldBlinding.toString(),
    transfer_value: transferAmount.toString(),
    transfer_blinding: transferBlinding.toString(),
    new_blinding: newBlinding.toString(),
    old_commit: [oldCommit.x.toString(), oldCommit.y.toString()],
    transfer_commit: [transferCommit.x.toString(), transferCommit.y.toString()],
    new_commit: [newCommit.x.toString(), newCommit.y.toString()],
  };

  // 3. Generate Groth16 proof via snarkjs
  const { proof: rawProof, publicSignals } = await snarkjs.groth16.fullProve(
    circuitInput,
    wasmPath,
    zkeyPath
  );

  // 4. Apply EIP-197 pi_b Fp2 swap
  const pB_swapped: [[string, string], [string, string]] = [
    [rawProof.pi_b[0][1], rawProof.pi_b[0][0]],
    [rawProof.pi_b[1][1], rawProof.pi_b[1][0]],
  ];

  // 5. Encode as uint256[8]
  const proof: [bigint, bigint, bigint, bigint, bigint, bigint, bigint, bigint] = [
    BigInt(rawProof.pi_a[0]),
    BigInt(rawProof.pi_a[1]),
    BigInt(pB_swapped[0][0]),
    BigInt(pB_swapped[0][1]),
    BigInt(pB_swapped[1][0]),
    BigInt(pB_swapped[1][1]),
    BigInt(rawProof.pi_c[0]),
    BigInt(rawProof.pi_c[1]),
  ];

  // 6. Public inputs as uint256[6]
  const publicInputs: [bigint, bigint, bigint, bigint, bigint, bigint] = [
    BigInt(publicSignals[0]),
    BigInt(publicSignals[1]),
    BigInt(publicSignals[2]),
    BigInt(publicSignals[3]),
    BigInt(publicSignals[4]),
    BigInt(publicSignals[5]),
  ];

  // 7. Optional local verification
  let locallyVerified = false;
  if (vkPath) {
    const { default: fs } = await import("fs");
    const vk = JSON.parse(fs.readFileSync(vkPath, "utf8"));
    locallyVerified = await snarkjs.groth16.verify(vk, publicSignals, rawProof);
  }

  return {
    proof,
    publicInputs,
    commitments: { oldCommit, transferCommit, newCommit },
    locallyVerified,
  };
}

/**
 * Format proof result for direct ethers.js contract call.
 */
export function formatForOnChain(result: TransferProofResult): {
  publicInputs: bigint[];
  proof: bigint[];
} {
  return {
    publicInputs: [...result.publicInputs],
    proof: [...result.proof],
  };
}
