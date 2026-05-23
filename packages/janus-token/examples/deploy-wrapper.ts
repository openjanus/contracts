/**
 * examples/deploy-wrapper.ts — Deploy a JanusToken in WRAPPER mode
 *
 * Shows how apps deploy their own JanusToken instances wrapping an ERC-20.
 * Example: JanusFLOW (wraps FLOW EVM token), JanusUSDC (wraps USDC).
 *
 * This is what PrivateTip does to create JanusFLOW:
 *   npx ts-node examples/deploy-wrapper.ts
 *
 * Usage:
 *   PRIVATE_KEY=0x... UNDERLYING_ADDRESS=0x... npx ts-node examples/deploy-wrapper.ts
 */

import { ethers } from "ethers";
import { NETWORK_CONFIG } from "../src";

// Canonical openjanus/primitives addresses (do not redeploy)
const VERIFIER  = "0x0085F286d89af79EC59E27CD0c5CcD1c55f42Cf5";
const BABY_JUB  = "0x2c40513b343B70f2A0B7e6Ad6F997DDa819D6f07";

// JanusToken constructor ABI
const ABI = [
  "constructor(address _verifier, address _babyJub, address underlying_)"
];

async function main() {
  const privateKey = process.env.PRIVATE_KEY;
  if (!privateKey) throw new Error("Set PRIVATE_KEY env var");

  const underlyingAddress = process.env.UNDERLYING_ADDRESS;
  if (!underlyingAddress) {
    console.log("No UNDERLYING_ADDRESS set. Deploying in NATIVE mode (no wrap/unwrap).");
    console.log("Set UNDERLYING_ADDRESS to deploy in WRAPPER mode.");
  }

  const underlying = underlyingAddress ?? ethers.ZeroAddress;

  const provider = new ethers.JsonRpcProvider(NETWORK_CONFIG.testnet.evmRpc);
  const wallet = new ethers.Wallet(privateKey, provider);

  console.log(`Deploying JanusToken...`);
  console.log(`  verifier:   ${VERIFIER}`);
  console.log(`  babyJub:    ${BABY_JUB}`);
  console.log(`  underlying: ${underlying}`);
  console.log(`  mode:       ${underlying === ethers.ZeroAddress ? "NATIVE" : "WRAPPER"}`);

  // Read JanusToken bytecode
  // In production: import from artifacts after `npm run compile`
  const fs = await import("fs");
  const path = await import("path");
  const artifactPath = path.join(__dirname, "../artifacts/contracts/solidity/JanusToken.sol/JanusToken.json");

  if (!fs.existsSync(artifactPath)) {
    console.error(`\nArtifact not found. Run 'npm run compile' first.`);
    process.exit(1);
  }

  const artifact = JSON.parse(fs.readFileSync(artifactPath, "utf8"));
  const factory = new ethers.ContractFactory(ABI, artifact.bytecode, wallet);
  const contract = await factory.deploy(VERIFIER, BABY_JUB, underlying);
  const receipt = await contract.deploymentTransaction()?.wait();

  const address = await contract.getAddress();
  console.log(`\nJanusToken deployed at: ${address}`);
  console.log(`Deploy tx: ${receipt?.hash}`);
  console.log(`\nUpdate your app's config with:`);
  console.log(`  address: "${address}"`);
  if (underlying !== ethers.ZeroAddress) {
    console.log(`  underlying: { address: "${underlying}", symbol: "???", decimals: 18 }`);
  }
}

main().catch(console.error);
