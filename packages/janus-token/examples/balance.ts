/**
 * examples/balance.ts — Read balance commitment from JanusToken
 *
 * Usage:
 *   ACCOUNT=0xYourAddress npx ts-node examples/balance.ts
 */

import { JanusToken, TESTNET_DEPLOYMENT } from "../src";

async function main() {
  const account = process.env.ACCOUNT ?? "0x0000000000000000000000000000000000000001";

  const token = new JanusToken({
    address: TESTNET_DEPLOYMENT.evm,
    network: "testnet",
  });
  await token.connect();

  const commit = await token.balanceOfCommitment(account);
  console.log(`Balance commitment for ${account}:`);
  console.log(`  x: ${commit.x}`);
  console.log(`  y: ${commit.y}`);
  console.log(`  Is identity (zero balance): ${commit.x === 0n && commit.y === 1n}`);

  const totalSupply = await token.totalSupplyCommitment();
  console.log(`\nTotal supply commitment:`);
  console.log(`  x: ${totalSupply.x}`);
  console.log(`  y: ${totalSupply.y}`);
}

main().catch(console.error);
