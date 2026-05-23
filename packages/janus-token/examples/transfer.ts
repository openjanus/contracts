/**
 * examples/transfer.ts — Confidential transfer with ZK proof
 *
 * Generates a Groth16 proof and submits it to JanusToken.confidentialTransfer.
 * Requires circuit artifacts (WASM + zkey).
 *
 * Usage:
 *   PRIVATE_KEY=0x... \
 *   RECIPIENT=0x... \
 *   OLD_BALANCE=100 \
 *   OLD_BLINDING=999 \
 *   TRANSFER_AMOUNT=30 \
 *   TRANSFER_BLINDING=12345 \
 *   NEW_BLINDING=67890 \
 *   WASM_PATH=/path/to/confidential_transfer.wasm \
 *   ZKEY_PATH=/path/to/confidential_transfer_final.zkey \
 *   npx ts-node examples/transfer.ts
 */

import { ethers } from "ethers";
import { JanusToken, TESTNET_DEPLOYMENT, NETWORK_CONFIG } from "../src";

async function main() {
  const privateKey = process.env.PRIVATE_KEY;
  if (!privateKey) throw new Error("Set PRIVATE_KEY env var");

  const recipient = process.env.RECIPIENT ?? "0x0000000000000000000000000000000000000002";
  const wasmPath = process.env.WASM_PATH;
  const zkeyPath = process.env.ZKEY_PATH;

  if (!wasmPath || !zkeyPath) {
    throw new Error("Set WASM_PATH and ZKEY_PATH env vars pointing to circuit artifacts");
  }

  const provider = new ethers.JsonRpcProvider(NETWORK_CONFIG.testnet.evmRpc);
  const wallet = new ethers.Wallet(privateKey, provider);

  const token = new JanusToken({
    address: TESTNET_DEPLOYMENT.evm,
    network: "testnet",
  });
  await token.connectWithSigner(wallet);

  console.log(`Generating proof and transferring to ${recipient}...`);
  const { receipt, proofResult } = await token.proveAndTransfer(recipient, {
    oldBalance: BigInt(process.env.OLD_BALANCE ?? "100"),
    oldBlinding: BigInt(process.env.OLD_BLINDING ?? "999999999"),
    transferAmount: BigInt(process.env.TRANSFER_AMOUNT ?? "30"),
    transferBlinding: BigInt(process.env.TRANSFER_BLINDING ?? "12345678"),
    newBlinding: BigInt(process.env.NEW_BLINDING ?? "98765432"),
    wasmPath,
    zkeyPath,
  });

  console.log(`  Proof locally verified: ${proofResult.locallyVerified}`);
  console.log(`  Transfer complete! Tx: ${receipt?.hash}`);
}

main().catch(console.error);
