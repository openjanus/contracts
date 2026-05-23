/**
 * examples/mint.ts — Mint a confidential commitment (NATIVE mode, owner only)
 *
 * Generates a Pedersen commitment off-chain and submits it to JanusToken.mintXY.
 *
 * Usage:
 *   PRIVATE_KEY=0x... RECIPIENT=0x... AMOUNT=100 BLINDING=999 npx ts-node examples/mint.ts
 */

import { ethers } from "ethers";
import { JanusToken, computeCommitment, TESTNET_DEPLOYMENT, NETWORK_CONFIG } from "../src";

async function main() {
  const privateKey = process.env.PRIVATE_KEY;
  if (!privateKey) throw new Error("Set PRIVATE_KEY env var");

  const recipient = process.env.RECIPIENT ?? "0x0000000000000000000000000000000000000001";
  const amount = BigInt(process.env.AMOUNT ?? "100");
  const blinding = BigInt(process.env.BLINDING ?? "999999999");

  const provider = new ethers.JsonRpcProvider(NETWORK_CONFIG.testnet.evmRpc);
  const wallet = new ethers.Wallet(privateKey, provider);

  const token = new JanusToken({
    address: TESTNET_DEPLOYMENT.evm,
    network: "testnet",
  });
  await token.connectWithSigner(wallet);

  console.log(`Minting ${amount} to ${recipient}...`);
  const commit = await computeCommitment(amount, blinding);
  console.log(`  Commitment: (${commit.x}, ${commit.y})`);

  const { receipt } = await token.mint(recipient, amount, blinding);
  console.log(`  Minted! Tx: ${receipt?.hash}`);
  console.log(`  IMPORTANT: Store your blinding factor: ${blinding}`);
  console.log(`  You need it to decrypt your balance later.`);
}

main().catch(console.error);
