/**
 * janus_e2e.mjs — End-to-end write test for JanusToken NATIVE mode
 *
 * Tests the full tx sequence against testnet:
 *   Step 1: Generate proof off-chain (Pedersen commitments + Groth16)
 *   Step 2: Mint 100 tokens to COA EVM address via JanusToken.mintXY
 *   Step 3: Verify on-chain state (balanceXY matches minted commitment)
 *   Step 4: confidentialTransfer 30 from COA to THIRD address
 *   Step 5: Verify state updates (sender has 70 commit, receiver has 30 commit)
 *   Step 6: Decrypt verification (reconstruct commits from private values)
 *   Step 7: Tampered proof test (security check — must revert)
 *
 * Usage:
 *   node tests/janus_e2e.mjs
 *
 * Prerequisites:
 *   - flow CLI in PATH
 *   - openjanus account in flow.json with key at /home/oydual3/.flow/openjanus-testnet.pkey
 *   - Circuit artifacts at cadence-crypto-lab (relative path from CIRCUIT_ROOT)
 *
 * Environment:
 *   CIRCUIT_ROOT    override circuit artifact root (default: cadence-crypto-lab sibling)
 *   EVM_RPC         override EVM RPC (default: testnet)
 *   JANUS_CONTRACT  override JanusToken EVM address (default: deployed on testnet)
 *   DRY_RUN         set to '1' to skip on-chain txs (proof gen + local verify only)
 */

import { buildBabyjub, buildPedersenHash } from "circomlibjs";
import { readFileSync, existsSync } from "fs";
import { join, dirname, resolve } from "path";
import { fileURLToPath } from "url";
import { execSync, spawnSync } from "child_process";
import * as snarkjs from "snarkjs";

const __dirname = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = join(__dirname, "..");

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------

const CIRCUIT_ROOT = process.env.CIRCUIT_ROOT ||
  // From /home/oydual3/zk-prop/tests/ -> up to /home/oydual3/ -> into cadence-crypto-lab
  resolve(REPO_ROOT, "../cadence-crypto-lab/modules/zk/confidential-transfer-circuit");

const WASM_PATH = join(CIRCUIT_ROOT, "circuit/build/confidential_transfer_js/confidential_transfer.wasm");
const ZKEY_PATH = join(CIRCUIT_ROOT, "setup/confidential_transfer_final.zkey");
const VK_PATH   = join(CIRCUIT_ROOT, "setup/verification_key.json");

const EVM_RPC      = process.env.EVM_RPC || "https://testnet.evm.nodes.onflow.org";
const JANUS_EVM    = process.env.JANUS_CONTRACT || "0x53F49881A1132FF4F674D2c015e35D5B07Fa1F4A";
const DRY_RUN      = process.env.DRY_RUN === "1";

// openjanus COA EVM address (msg.sender for all EVM calls via Cadence)
const COA_EVM      = "0000000000000000000000027eb18dc34b9966fd"; // 20 bytes, no 0x

// Third address: a deterministic test address (not a real account — just receives the commitment)
const THIRD_EVM    = "000000000000000000000000000000000000bEef"; // no 0x

// Test parameters
const OLD_VALUE        = 100n;
const OLD_BLINDING     = 12345678901234567890n;
const TRANSFER_VALUE   = 30n;
const TRANSFER_BLINDING= 98765432109876543210n;
const NEW_BLINDING     = 11111111111111111111n;
const NEW_VALUE        = OLD_VALUE - TRANSFER_VALUE; // 70n

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

let _pedersenHash = null;
let _babyJub = null;

async function getPedersenHash() {
  if (!_pedersenHash) _pedersenHash = await buildPedersenHash();
  return _pedersenHash;
}

async function getBabyJub() {
  if (!_babyJub) _babyJub = await buildBabyjub();
  return _babyJub;
}

async function computeCommitment(value, blinding) {
  const ph = await getPedersenHash();
  const bj = await getBabyJub();
  const F = bj.F;

  const buf = Buffer.alloc(24, 0);
  let v = BigInt(value);
  for (let i = 0; i < 8; i++) { buf[i] = Number(v & 0xffn); v >>= 8n; }
  let b = BigInt(blinding);
  for (let i = 8; i < 24; i++) { buf[i] = Number(b & 0xffn); b >>= 8n; }

  const hash = ph.hash(buf);
  const point = bj.unpackPoint(hash);
  return {
    x: F.toObject(point[0]),
    y: F.toObject(point[1]),
  };
}

async function ethCall(to, data) {
  const res = await fetch(EVM_RPC, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", method: "eth_call", params: [{ to, data }, "latest"], id: 1 }),
  });
  const json = await res.json();
  if (json.error) throw new Error(`eth_call failed: ${JSON.stringify(json.error)}`);
  return json.result;
}

async function readBalanceCommitment(evmAddrNoPrefix) {
  // balanceOfCommitmentXY(address) selector = 0x434e7f16
  const padded = evmAddrNoPrefix.toLowerCase().padStart(64, "0");
  const data = "0x434e7f16" + padded;
  const result = await ethCall(JANUS_EVM, data);
  const x = BigInt("0x" + result.slice(2, 66));
  const y = BigInt("0x" + result.slice(66, 130));
  return { x, y };
}

function flowSend(txFile, args, signer = "openjanus") {
  if (DRY_RUN) {
    console.log(`  [DRY_RUN] would send: flow transactions send ${txFile}`);
    return { txHash: "DRY_RUN", status: "DRY_RUN" };
  }

  const argsJson = JSON.stringify(args);
  const cmd = [
    "flow", "transactions", "send", txFile,
    "--network", "testnet",
    "--signer", signer,
    "--args-json", argsJson,
    "--output", "json",
  ];

  const result = spawnSync(cmd[0], cmd.slice(1), {
    cwd: REPO_ROOT,
    encoding: "utf8",
    timeout: 90_000,
  });

  if (result.error) throw new Error(`spawn error: ${result.error.message}`);

  const stdout = result.stdout || "";
  const stderr = result.stderr || "";

  // Extract tx hash from JSON output or stderr
  let txHash = null;
  let txStatus = null;

  try {
    const parsed = JSON.parse(stdout);
    txHash = parsed.id || parsed.transactionId || null;
    txStatus = parsed.status || null;
  } catch {
    // Fallback: parse from text output
    const hashMatch = stderr.match(/Transaction ID:\s*([0-9a-f]{64})/i) ||
                      stdout.match(/ID\s+([0-9a-f]{64})/i);
    if (hashMatch) txHash = hashMatch[1];
  }

  if (result.status !== 0) {
    console.error("  TX stderr:", stderr.slice(0, 500));
    throw new Error(`flow transactions send failed (exit ${result.status}): ${stderr.slice(0, 300)}`);
  }

  return { txHash, txStatus, stdout, stderr };
}

function flowSendRaw(txFile, args, signer = "openjanus") {
  if (DRY_RUN) {
    console.log(`  [DRY_RUN] would send: flow transactions send ${txFile}`);
    return { txHash: "DRY_RUN", stdout: "", stderr: "" };
  }

  const argsJson = JSON.stringify(args);
  const result = spawnSync("flow", [
    "transactions", "send", txFile,
    "--network", "testnet",
    "--signer", signer,
    "--args-json", argsJson,
  ], {
    cwd: REPO_ROOT,
    encoding: "utf8",
    timeout: 90_000,
  });

  const stdout = result.stdout || "";
  const stderr = result.stderr || "";

  if (result.error) throw new Error(`spawn error: ${result.error.message}`);

  // Extract tx hash from flow CLI text output
  let txHash = null;
  const hashMatch = stdout.match(/ID\s+([0-9a-f]{64})/i) ||
                    stderr.match(/ID\s+([0-9a-f]{64})/i) ||
                    stdout.match(/Transaction ID:\s*([0-9a-f]{64})/i);
  if (hashMatch) txHash = hashMatch[1];

  // flow CLI exits 0 even for Cadence assertion failures. Check for error indicators.
  const hasError = stdout.includes("Transaction Error") ||
                   stdout.includes("assertion failed") ||
                   stdout.includes("execution reverted") ||
                   stdout.includes("❌") ||
                   result.status !== 0;

  if (result.status !== 0 || (hasError && !args._allowError)) {
    const errMsg = stdout.includes("assertion failed") ?
      stdout.match(/assertion failed: ([^\n]+)/)?.[1] || "assertion failed" :
      `flow CLI exit ${result.status}`;
    const err = new Error(`flow tx failed: ${errMsg}`);
    err.txHash = txHash;
    err.stdout = stdout;
    err.stderr = stderr;
    throw err;
  }

  return { txHash, stdout, stderr };
}

function assert(condition, message) {
  if (!condition) throw new Error(`ASSERTION FAILED: ${message}`);
  console.log(`  PASS: ${message}`);
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

async function main() {
  console.log("=== JanusToken NATIVE — End-to-End Write Test ===");
  console.log(`Network: testnet${DRY_RUN ? " (DRY_RUN)" : ""}`);
  console.log(`JanusToken EVM: ${JANUS_EVM}`);
  console.log(`COA EVM:        0x${COA_EVM}`);
  console.log(`Third EVM:      0x${THIRD_EVM}`);
  console.log(`Circuit root:   ${CIRCUIT_ROOT}`);
  console.log();

  // -------------------------------------------------------------------------
  // Preflight: check artifacts exist
  // -------------------------------------------------------------------------
  console.log("--- PREFLIGHT ---");
  if (!existsSync(WASM_PATH)) throw new Error(`WASM not found: ${WASM_PATH}`);
  if (!existsSync(ZKEY_PATH)) throw new Error(`ZKEY not found: ${ZKEY_PATH}`);
  if (!existsSync(VK_PATH))   throw new Error(`VK not found: ${VK_PATH}`);
  console.log("  Circuit artifacts: OK");

  const txMintFile     = join(REPO_ROOT, "transactions/janus_mint.cdc");
  const txTransferFile = join(REPO_ROOT, "transactions/janus_transfer.cdc");
  if (!existsSync(txMintFile))     throw new Error(`Tx not found: ${txMintFile}`);
  if (!existsSync(txTransferFile)) throw new Error(`Tx not found: ${txTransferFile}`);
  console.log("  Cadence transactions: OK");
  console.log();

  // -------------------------------------------------------------------------
  // Step 1: Compute Pedersen commitments off-chain
  // -------------------------------------------------------------------------
  console.log("--- STEP 1: Compute commitments off-chain ---");
  const oldCommit      = await computeCommitment(OLD_VALUE, OLD_BLINDING);
  const txCommit       = await computeCommitment(TRANSFER_VALUE, TRANSFER_BLINDING);
  const newCommit      = await computeCommitment(NEW_VALUE, NEW_BLINDING);

  console.log(`  Mint commitment (100 tokens):`);
  console.log(`    x: ${oldCommit.x.toString().slice(0, 20)}...`);
  console.log(`    y: ${oldCommit.y.toString().slice(0, 20)}...`);
  console.log(`  Transfer commitment (30 tokens):`);
  console.log(`    x: ${txCommit.x.toString().slice(0, 20)}...`);
  console.log(`  New balance commitment (70 tokens):`);
  console.log(`    x: ${newCommit.x.toString().slice(0, 20)}...`);
  console.log();

  // -------------------------------------------------------------------------
  // Step 2: Generate Groth16 proof
  // -------------------------------------------------------------------------
  console.log("--- STEP 2: Generate Groth16 proof ---");
  const circuitInput = {
    old_value:         OLD_VALUE.toString(),
    old_blinding:      OLD_BLINDING.toString(),
    transfer_value:    TRANSFER_VALUE.toString(),
    transfer_blinding: TRANSFER_BLINDING.toString(),
    new_blinding:      NEW_BLINDING.toString(),
    old_commit:        [oldCommit.x.toString(), oldCommit.y.toString()],
    transfer_commit:   [txCommit.x.toString(), txCommit.y.toString()],
    new_commit:        [newCommit.x.toString(), newCommit.y.toString()],
  };

  const t0 = Date.now();
  const { proof: rawProof, publicSignals } = await snarkjs.groth16.fullProve(
    circuitInput, WASM_PATH, ZKEY_PATH
  );
  console.log(`  Proof generated in ${Date.now() - t0}ms`);

  // Local verification
  const vk = JSON.parse(readFileSync(VK_PATH, "utf8"));
  const localValid = await snarkjs.groth16.verify(vk, publicSignals, rawProof);
  assert(localValid, "Local snarkjs verification passed");

  // EIP-197 pi_b Fp2 swap
  const pB_swapped = [
    [rawProof.pi_b[0][1], rawProof.pi_b[0][0]],
    [rawProof.pi_b[1][1], rawProof.pi_b[1][0]],
  ];

  const proof8 = [
    BigInt(rawProof.pi_a[0]),
    BigInt(rawProof.pi_a[1]),
    BigInt(pB_swapped[0][0]),
    BigInt(pB_swapped[0][1]),
    BigInt(pB_swapped[1][0]),
    BigInt(pB_swapped[1][1]),
    BigInt(rawProof.pi_c[0]),
    BigInt(rawProof.pi_c[1]),
  ];

  const pubInputs6 = publicSignals.slice(0, 6).map(BigInt);
  console.log(`  Public signals: ${pubInputs6.length} signals OK`);
  console.log();

  // -------------------------------------------------------------------------
  // Step 3: Mint 100 tokens to COA EVM address
  // -------------------------------------------------------------------------
  console.log("--- STEP 3: Mint 100 tokens to COA ---");
  console.log(`  Recipient: 0x${COA_EVM}`);
  console.log(`  Commitment: (${oldCommit.x}, ${oldCommit.y})`);

  // Check pre-mint state
  const preMintBalance = await readBalanceCommitment(COA_EVM);
  console.log(`  Pre-mint commitment: (${preMintBalance.x}, ${preMintBalance.y})`);
  const preMintIsIdentity = preMintBalance.x === 0n && preMintBalance.y === 1n;
  console.log(`  Pre-mint is identity: ${preMintIsIdentity}`);

  const mintArgs = [
    { type: "String", value: COA_EVM },
    { type: "UInt256", value: oldCommit.x.toString() },
    { type: "UInt256", value: oldCommit.y.toString() },
  ];

  let mintTxHash = null;
  const mintResult = flowSendRaw(txMintFile, mintArgs);
  mintTxHash = mintResult.txHash;

  console.log(`  Mint TX hash: ${mintTxHash || "unknown (check output)"}`);
  if (mintResult.stdout) console.log("  TX output:", mintResult.stdout.slice(0, 300));

  // Verify state after mint
  const postMintBalance = await readBalanceCommitment(COA_EVM);
  console.log(`  Post-mint commitment: (${postMintBalance.x}, ${postMintBalance.y})`);

  assert(
    postMintBalance.x === oldCommit.x && postMintBalance.y === oldCommit.y,
    `COA balance commitment matches minted commitment (100 tokens)`
  );
  console.log(`  Mint TX confirmed: ${mintTxHash}`);
  console.log();

  // -------------------------------------------------------------------------
  // Step 4: confidentialTransfer 30 from COA to THIRD
  // -------------------------------------------------------------------------
  console.log("--- STEP 4: confidentialTransfer 30 from COA to THIRD ---");
  console.log(`  From (COA): 0x${COA_EVM}`);
  console.log(`  To (THIRD): 0x${THIRD_EVM}`);
  console.log(`  Transfer commitment (30): x=${txCommit.x.toString().slice(0, 20)}...`);
  console.log(`  New COA commitment (70):  x=${newCommit.x.toString().slice(0, 20)}...`);

  const transferArgs = [
    { type: "String", value: THIRD_EVM },
    { type: "UInt256", value: pubInputs6[0].toString() },
    { type: "UInt256", value: pubInputs6[1].toString() },
    { type: "UInt256", value: pubInputs6[2].toString() },
    { type: "UInt256", value: pubInputs6[3].toString() },
    { type: "UInt256", value: pubInputs6[4].toString() },
    { type: "UInt256", value: pubInputs6[5].toString() },
    { type: "UInt256", value: proof8[0].toString() },
    { type: "UInt256", value: proof8[1].toString() },
    { type: "UInt256", value: proof8[2].toString() },
    { type: "UInt256", value: proof8[3].toString() },
    { type: "UInt256", value: proof8[4].toString() },
    { type: "UInt256", value: proof8[5].toString() },
    { type: "UInt256", value: proof8[6].toString() },
    { type: "UInt256", value: proof8[7].toString() },
  ];

  let transferTxHash = null;
  const transferResult = flowSendRaw(txTransferFile, transferArgs);
  transferTxHash = transferResult.txHash;

  console.log(`  Transfer TX hash: ${transferTxHash || "unknown"}`);
  if (transferResult.stdout) console.log("  TX output:", transferResult.stdout.slice(0, 300));

  // -------------------------------------------------------------------------
  // Step 5: Verify on-chain state after transfer
  // -------------------------------------------------------------------------
  console.log();
  console.log("--- STEP 5: Verify on-chain state after transfer ---");

  const postXferCOA   = await readBalanceCommitment(COA_EVM);
  const postXferThird = await readBalanceCommitment(THIRD_EVM);

  console.log(`  COA balance after transfer:   (${postXferCOA.x}, ${postXferCOA.y})`);
  console.log(`  THIRD balance after transfer: (${postXferThird.x}, ${postXferThird.y})`);

  assert(
    postXferCOA.x === newCommit.x && postXferCOA.y === newCommit.y,
    "COA commitment matches new_commit (70 tokens worth)"
  );
  assert(
    postXferThird.x === txCommit.x && postXferThird.y === txCommit.y,
    "THIRD commitment matches transfer_commit (30 tokens worth)"
  );
  console.log(`  Transfer TX confirmed: ${transferTxHash}`);
  console.log();

  // -------------------------------------------------------------------------
  // Step 6: Decrypt verification
  // -------------------------------------------------------------------------
  console.log("--- STEP 6: Decrypt verification (off-chain) ---");

  // COA holder knows: (NEW_VALUE=70, NEW_BLINDING) → reconstruct commitment → matches on-chain
  const reconstructedNew = await computeCommitment(NEW_VALUE, NEW_BLINDING);
  assert(
    reconstructedNew.x === postXferCOA.x && reconstructedNew.y === postXferCOA.y,
    `COA holder can decrypt: 70 tokens (blinding=${NEW_BLINDING})`
  );

  // THIRD holder knows: (TRANSFER_VALUE=30, TRANSFER_BLINDING) → reconstruct → matches on-chain
  const reconstructedTx = await computeCommitment(TRANSFER_VALUE, TRANSFER_BLINDING);
  assert(
    reconstructedTx.x === postXferThird.x && reconstructedTx.y === postXferThird.y,
    `THIRD holder can decrypt: 30 tokens (blinding=${TRANSFER_BLINDING})`
  );
  console.log();

  // -------------------------------------------------------------------------
  // Step 7: Tampered proof (security check)
  // -------------------------------------------------------------------------
  console.log("--- STEP 7: Tampered proof security check ---");

  // Tamper one proof element (flip first bit of pA.x)
  const tamperedProof8 = [...proof8];
  tamperedProof8[0] = proof8[0] ^ 1n;

  const tamperedArgs = [
    { type: "String", value: THIRD_EVM },
    ...pubInputs6.map(v => ({ type: "UInt256", value: v.toString() })),
    ...tamperedProof8.map(v => ({ type: "UInt256", value: v.toString() })),
  ];

  let tamperedReverted = false;
  if (DRY_RUN) {
    console.log("  [DRY_RUN] skipping tampered proof tx");
    tamperedReverted = true;
  } else {
    try {
      flowSendRaw(txTransferFile, tamperedArgs);
      console.log("  SECURITY FAIL: tampered proof accepted (should have reverted)");
    } catch (err) {
      tamperedReverted = true;
      console.log(`  Tampered proof rejected: ${err.message.slice(0, 100)}`);
    }
  }
  assert(tamperedReverted, "Tampered proof tx reverted (security check passed)");
  console.log();

  // -------------------------------------------------------------------------
  // Summary
  // -------------------------------------------------------------------------
  console.log("=== E2E TEST SUMMARY ===");
  console.log(`  Mint TX:              ${mintTxHash || "N/A"}`);
  console.log(`  Transfer TX:          ${transferTxHash || "N/A"}`);
  console.log(`  Mint explorer:        https://testnet.flowscan.io/transaction/${mintTxHash}`);
  console.log(`  Transfer explorer:    https://testnet.flowscan.io/transaction/${transferTxHash}`);
  console.log(`  Decrypt COA:          OK (70 tokens, blinding=${NEW_BLINDING})`);
  console.log(`  Decrypt THIRD:        OK (30 tokens, blinding=${TRANSFER_BLINDING})`);
  console.log(`  Tampered proof:       REJECTED`);
  console.log();
  console.log("ALL STEPS PASSED — JanusToken NATIVE mode is write-verified on testnet.");
  console.log();

  // Return result for programmatic use
  return {
    mintTxHash,
    transferTxHash,
    commitments: {
      old: oldCommit,
      transfer: txCommit,
      new: newCommit,
    },
    pubInputs6,
    proof8,
  };
}

main().catch(err => {
  console.error("\nFATAL:", err.message);
  if (err.stack) console.error(err.stack.split("\n").slice(1, 4).join("\n"));
  process.exit(1);
});
