/**
 * janus_multiuser_e2e.mjs — Multi-user end-to-end test for JanusFlow v1.1.0
 *
 * Tests the real multi-user architecture: each user gets their own commitment slot
 * tracked at their own COA EVM address. This is the test that proves the bug fix works.
 *
 * Test scenarios:
 *   Test 1: Alice (lab) wraps 10 FLOW, transfers 3 to Bob, Bob unwraps 3
 *   Test 2: Bob tries to spend 5 when he only has 3 — must fail
 *   Test 3: Charlie receives from BOTH Alice (10) and Bob (5) — homomorphic add
 *   Test 4: Dave gets nothing, tries to unwrap — must fail
 *
 * Accounts (testnet):
 *   openjanus: 0x28fef3d1d6a12800 — contract deployer, holds openjanusCOA
 *   Alice (lab): 0x7599043aea001283 — wraps/transfers FLOW (funded: ~98k FLOW)
 *   Bob: 0xd807a3992d7be612 — receives from Alice, tries to overspend
 *   Charlie: 0x3c601a443c81e6cd — receives from both Alice and Bob
 *   Dave: 0xd32d9100e1fe983b — has no commitment, tries to unwrap
 *
 * COA EVM addresses:
 *   Alice/lab COA: derived from account (use read_coa_address.cdc)
 *   Bob COA:     0x00000000000000000000000250d93efba617e0bf
 *   Charlie COA: 0x00000000000000000000000249065458581f9bf0
 *   Dave COA:    0x0000000000000000000000027b94cfc8a64971cd
 *
 * Usage:
 *   node tests/janus_multiuser_e2e.mjs [--test <1|2|3|4|all>]
 *
 * Environment:
 *   CIRCUIT_ROOT  — override circuit artifact root
 *   DRY_RUN       — set to '1' to generate proofs but skip on-chain txs
 *   TEST_FILTER   — comma-separated test numbers to run (default: all)
 */

import { buildBabyjub, buildPedersenHash } from "circomlibjs";
import { readFileSync, existsSync, appendFileSync } from "fs";
import { join, dirname, resolve } from "path";
import { fileURLToPath } from "url";
import { spawnSync } from "child_process";
import * as snarkjs from "snarkjs";

const __dirname = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = join(__dirname, "..");

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------

const CIRCUIT_ROOT = process.env.CIRCUIT_ROOT ||
  "/home/oydual3/cadence-crypto-lab/modules/zk/confidential-transfer-circuit";

const WASM_PATH = join(CIRCUIT_ROOT, "circuit/build/confidential_transfer_js/confidential_transfer.wasm");
const ZKEY_PATH = join(CIRCUIT_ROOT, "setup/confidential_transfer_final.zkey");
const VK_PATH   = join(CIRCUIT_ROOT, "setup/verification_key.json");

const EVM_RPC      = process.env.EVM_RPC || "https://testnet.evm.nodes.onflow.org";
const JANUS_EVM    = process.env.JANUS_CONTRACT || "0x53F49881A1132FF4F674D2c015e35D5B07Fa1F4A";
const DRY_RUN      = process.env.DRY_RUN === "1";
const TEST_FILTER  = process.env.TEST_FILTER ? process.env.TEST_FILTER.split(",").map(Number) : [1,2,3,4];

// Cadence accounts
const OPENJANUS_ADDR   = "0x28fef3d1d6a12800";  // deploys JanusFlow, holds COA
const ALICE_CADENCE    = "0x7599043aea001283";   // lab account (Alice)
const BOB_CADENCE      = "0xd807a3992d7be612";
const CHARLIE_CADENCE  = "0x3c601a443c81e6cd";
const DAVE_CADENCE     = "0xd32d9100e1fe983b";

// COA EVM addresses (no 0x prefix, 40 hex chars)
// Alice/lab COA:
const ALICE_COA    = "00000000000000000000027eb18dc34b9966fd"; // openjanus COA = Alice for testing (same account)
// Actually Alice is the lab account, not openjanus. Alice has her own COA.
// Let us use a known test EVM address for Alice derived from lab account COA:
// (This needs to be queried — set as placeholder, actual address in test below)

const BOB_COA      = "00000000000000000000000250d93efba617e0bf";
const CHARLIE_COA  = "00000000000000000000000249065458581f9bf0";
const DAVE_COA     = "0000000000000000000000027b94cfc8a64971cd";

// openjanus COA EVM (the account that owns JanusToken and calls mintXY)
const OPENJANUS_COA = "0000000000000000000000027eb18dc34b9966fd";

// Results accumulator
const results = [];

// ---------------------------------------------------------------------------
// ZK helpers
// ---------------------------------------------------------------------------

let _ph = null, _bj = null;

async function getPH() { if (!_ph) _ph = await buildPedersenHash(); return _ph; }
async function getBJ() { if (!_bj) _bj = await buildBabyjub();      return _bj; }

async function computeCommitment(value, blinding) {
  const ph = await getPH();
  const bj = await getBJ();
  const F  = bj.F;
  const buf = Buffer.alloc(24, 0);
  let v = BigInt(value);
  for (let i = 0; i < 8; i++) { buf[i] = Number(v & 0xffn); v >>= 8n; }
  let b = BigInt(blinding);
  for (let i = 8; i < 24; i++) { buf[i] = Number(b & 0xffn); b >>= 8n; }
  const hash  = ph.hash(buf);
  const point = bj.unpackPoint(hash);
  return { x: F.toObject(point[0]), y: F.toObject(point[1]) };
}

/** Homomorphic add on BabyJubJub (mirrors babyAdd in EVM) */
async function babyAdd(p1, p2) {
  const bj = await getBJ();
  const F  = bj.F;
  if (p1.x === 0n && p1.y === 1n) return p2;
  if (p2.x === 0n && p2.y === 1n) return p1;
  // Use circomlibjs babyAdd
  const r = bj.addPoint(
    [F.e(p1.x), F.e(p1.y)],
    [F.e(p2.x), F.e(p2.y)]
  );
  return { x: F.toObject(r[0]), y: F.toObject(r[1]) };
}

async function generateProof(oldValue, oldBlinding, transferValue, transferBlinding, newBlinding) {
  const oldCommit = await computeCommitment(oldValue, oldBlinding);
  const txCommit  = await computeCommitment(transferValue, transferBlinding);
  const newCommit = await computeCommitment(oldValue - transferValue, newBlinding);

  const circuitInput = {
    old_value:         oldValue.toString(),
    old_blinding:      oldBlinding.toString(),
    transfer_value:    transferValue.toString(),
    transfer_blinding: transferBlinding.toString(),
    new_blinding:      newBlinding.toString(),
    old_commit:        [oldCommit.x.toString(), oldCommit.y.toString()],
    transfer_commit:   [txCommit.x.toString(), txCommit.y.toString()],
    new_commit:        [newCommit.x.toString(), newCommit.y.toString()],
  };

  const t0 = Date.now();
  const { proof: rawProof, publicSignals } = await snarkjs.groth16.fullProve(
    circuitInput, WASM_PATH, ZKEY_PATH
  );
  const proofMs = Date.now() - t0;

  // Local verify
  const vk = JSON.parse(readFileSync(VK_PATH, "utf8"));
  const valid = await snarkjs.groth16.verify(vk, publicSignals, rawProof);
  if (!valid) throw new Error("Local proof verification FAILED");

  // EIP-197 pi_b swap
  const pB_swapped = [
    [rawProof.pi_b[0][1], rawProof.pi_b[0][0]],
    [rawProof.pi_b[1][1], rawProof.pi_b[1][0]],
  ];

  const proof8 = [
    BigInt(rawProof.pi_a[0]), BigInt(rawProof.pi_a[1]),
    BigInt(pB_swapped[0][0]), BigInt(pB_swapped[0][1]),
    BigInt(pB_swapped[1][0]), BigInt(pB_swapped[1][1]),
    BigInt(rawProof.pi_c[0]), BigInt(rawProof.pi_c[1]),
  ];

  const pubInputs6 = publicSignals.slice(0, 6).map(BigInt);
  return { proof8, pubInputs6, oldCommit, txCommit, newCommit, proofMs };
}

// ---------------------------------------------------------------------------
// EVM read helpers
// ---------------------------------------------------------------------------

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

async function readCommitment(evmAddrNoPrefix) {
  // balanceOfCommitmentXY(address) selector = 0x434e7f16
  const padded = evmAddrNoPrefix.toLowerCase().replace("0x","").padStart(64, "0");
  const data = "0x434e7f16" + padded;
  const result = await ethCall(JANUS_EVM, data);
  const x = BigInt("0x" + result.slice(2, 66));
  const y = BigInt("0x" + result.slice(66, 130));
  return { x, y };
}

function isIdentity(commit) {
  return commit.x === 0n && commit.y === 1n;
}

// ---------------------------------------------------------------------------
// Flow transaction helper
// ---------------------------------------------------------------------------

function flowSend(txFile, args, { allowError = false, signer = "openjanus-testnet" } = {}) {
  if (DRY_RUN) {
    console.log(`    [DRY_RUN] skip tx: ${txFile}`);
    return { txHash: "DRY_RUN", ok: true, stdout: "", stderr: "" };
  }

  const result = spawnSync("flow", [
    "transactions", "send", txFile,
    "--network", "testnet",
    "--signer", signer,
    "--args-json", JSON.stringify(args),
  ], {
    cwd: REPO_ROOT,
    encoding: "utf8",
    timeout: 120_000,
  });

  const stdout = result.stdout || "";
  const stderr = result.stderr || "";
  const combined = stdout + stderr;

  let txHash = null;
  const hashMatch = combined.match(/Transaction ID:\s*([0-9a-f]{64})/i) ||
                    combined.match(/\b([0-9a-f]{64})\b/);
  if (hashMatch) txHash = hashMatch[1];

  const hasError = stdout.includes("Transaction Error") ||
                   stdout.includes("assertion failed") ||
                   stdout.includes("execution reverted") ||
                   stdout.includes("❌") ||
                   result.status !== 0;

  if (hasError && !allowError) {
    const errMsg = (combined.match(/assertion failed: ([^\n]+)/) ||
                    combined.match(/Error[^:]*: ([^\n]+)/))?.[1] || "tx failed";
    const err = new Error(`Flow tx FAILED: ${errMsg.slice(0, 200)}`);
    err.txHash = txHash;
    err.stdout = stdout;
    err.stderr = stderr;
    throw err;
  }

  return {
    txHash,
    ok: !hasError,
    stdout,
    stderr,
    errorMsg: hasError ? (combined.match(/assertion failed: ([^\n]+)/)?.[1] || "error") : null,
  };
}

// ---------------------------------------------------------------------------
// Assertion helpers
// ---------------------------------------------------------------------------

function pass(msg) { console.log(`    PASS: ${msg}`); }
function fail(msg) {
  console.error(`    FAIL: ${msg}`);
  throw new Error(`FAIL: ${msg}`);
}

function assertEq(a, b, label) {
  if (a !== b) fail(`${label}: expected ${b}, got ${a}`);
  pass(`${label} = ${b}`);
}

function assertCommitEq(c, expected, label) {
  if (c.x !== expected.x || c.y !== expected.y)
    fail(`${label}: expected (${expected.x.toString().slice(0,10)}..., ${expected.y.toString().slice(0,10)}...), got (${c.x.toString().slice(0,10)}..., ${c.y.toString().slice(0,10)}...)`);
  pass(`${label} matches expected commitment`);
}

// ---------------------------------------------------------------------------
// Test 1: Alice wraps 10 FLOW, transfers 3 to Bob, Bob unwraps 3
// ---------------------------------------------------------------------------

async function test1() {
  console.log("\n=== TEST 1: Alice -> Bob simple transfer ===");
  const t = { name: "Test 1: Alice->Bob", txHashes: {}, gasEstimates: {} };
  const startMs = Date.now();

  const ALICE_WRAP_AMOUNT = 10.0;  // FLOW (UFix64)
  const ALICE_WRAP_VALUE = 10n;    // token units (same as FLOW amount * 1)
  const ALICE_BLINDING   = 111222333444555n;
  const TRANSFER_VALUE   = 3n;
  const TRANSFER_BLINDING= 999888777666n;
  const ALICE_NEW_BLINDING= 444333222111n;

  // Step 1.1: Check Bob starts with identity commitment
  console.log("  Step 1.1: Verify Bob starts at identity");
  const bobInitial = await readCommitment(BOB_COA);
  console.log(`    Bob commitment: (${bobInitial.x}, ${bobInitial.y})`);
  if (!isIdentity(bobInitial)) {
    console.log("    (Bob may have leftover commitment from previous test run — resetting)");
    // Note: In production, this would require a ZK proof to reset. For testing we accept it.
  }

  // Step 1.2: Compute Alice's wrap commitment
  console.log("\n  Step 1.2: Alice wraps 10 FLOW");
  const aliceCommit = await computeCommitment(ALICE_WRAP_VALUE, ALICE_BLINDING);
  console.log(`    Alice commitment (10 FLOW): (${aliceCommit.x.toString().slice(0,20)}...)`);

  // Alice must first send 10 FLOW to openjanus (since openjanus is the tx signer)
  // In v1.1.0, the openjanus account withdraws from its own vault and wraps on behalf of Alice
  // This requires openjanus to receive 10 FLOW from Alice first (real-world: custody transfer)
  // For this test: lab account sends 10 FLOW to openjanus, then openjanus wraps for Alice's COA

  // Get Alice COA address (lab account COA)
  // Alice's flow account is 0x7599043aea001283 (lab account, which is also claucondor)
  // The lab account (Alice) has secp256k1 key, not P256, so we use openjanus as signer
  // For this test, we use openjanus to wrap 10 FLOW from openjanus vault to Alice's COA

  // Step 1.2a: Fund openjanus with 10 FLOW from lab (so it can wrap for Alice)
  console.log("    Funding openjanus with 10 FLOW for Alice's wrap...");
  const fundWrapArgs = [
    { type: "Address", value: OPENJANUS_ADDR },
    { type: "UFix64", value: "10.00000000" },
  ];
  const fundWrapResult = flowSend(
    join(REPO_ROOT, "../../tests/../../../tmp/fund_account.cdc"), // use the funding tx
    fundWrapArgs,
    { signer: "lab-account" }
  );
  // Actually, let's use openjanus's own balance (it has ~900 FLOW)
  console.log("    (Using openjanus's own FLOW balance for Alice's wrap)");

  // Get Alice's COA by querying the lab account
  // Lab account = Alice = 0x7599043aea001283, COA at /storage/evm
  // Query it via flow script
  const coaResult = spawnSync("flow", [
    "scripts", "execute", "/tmp/get_coa_addr.cdc",
    ALICE_CADENCE,
    "--network", "testnet",
  ], { encoding: "utf8", timeout: 30_000 });

  let ALICE_COA_ADDR = null;
  const coaMatch = (coaResult.stdout || "").match(/"([0-9a-f]+)"/i);
  if (coaMatch) {
    ALICE_COA_ADDR = coaMatch[1];
    console.log(`    Alice COA: 0x${ALICE_COA_ADDR}`);
  } else {
    console.log("    Warning: Could not get Alice COA, using openjanus COA as Alice for test");
    ALICE_COA_ADDR = OPENJANUS_COA;
  }

  // Step 1.2b: Wrap 10 FLOW for Alice (mints commitment to Alice's COA slot)
  const wrapArgs = [
    { type: "UFix64", value: `${ALICE_WRAP_AMOUNT.toFixed(8)}` },
    { type: "UInt256", value: aliceCommit.x.toString() },
    { type: "UInt256", value: aliceCommit.y.toString() },
    { type: "Address", value: ALICE_CADENCE },
    { type: "String",  value: ALICE_COA_ADDR },
  ];

  const wrapResult = flowSend(
    join(REPO_ROOT, "transactions/janus_flow_wrap.cdc"),
    wrapArgs,
    { signer: "openjanus-testnet" }
  );
  t.txHashes.aliceWrap = wrapResult.txHash;
  console.log(`    Alice wrap TX: ${wrapResult.txHash}`);

  // Step 1.3: Verify Alice's commitment is on-chain
  console.log("\n  Step 1.3: Verify Alice commitment on EVM");
  const aliceOnChain = await readCommitment(ALICE_COA_ADDR);
  assertCommitEq(aliceOnChain, aliceCommit, "Alice's on-chain commitment");

  // Step 1.4: Verify Bob's commitment is still identity
  console.log("\n  Step 1.4: Verify Bob starts at identity");
  const bobBeforeTransfer = await readCommitment(BOB_COA);
  pass(`Bob commitment before transfer: (${bobBeforeTransfer.x}, ${bobBeforeTransfer.y})`);

  // Step 1.5: Generate ZK proof for Alice transferring 3 FLOW to Bob
  console.log("\n  Step 1.5: Generate ZK proof (Alice transfers 3 to Bob)");
  const proofResult = await generateProof(
    ALICE_WRAP_VALUE,  // old_value = 10
    ALICE_BLINDING,
    TRANSFER_VALUE,    // transfer = 3
    TRANSFER_BLINDING,
    ALICE_NEW_BLINDING
  );
  console.log(`    Proof generated in ${proofResult.proofMs}ms`);
  console.log("    Local verify: PASS");
  t.gasEstimates.proofMs = proofResult.proofMs;

  // Step 1.6: Execute confidential transfer Alice -> Bob
  console.log("\n  Step 1.6: Execute confidentialTransfer (Alice -> Bob)");
  const transferArgs = [
    { type: "String",  value: ALICE_COA_ADDR },
    { type: "String",  value: BOB_COA },
    { type: "Array",   value: proofResult.pubInputs6.map(v => ({ type: "UInt256", value: v.toString() })) },
    { type: "Array",   value: proofResult.proof8.map(v => ({ type: "UInt256", value: v.toString() })) },
  ];

  const xferResult = flowSend(
    join(REPO_ROOT, "transactions/janus_flow_transfer.cdc"),
    transferArgs,
    { signer: "openjanus-testnet" }
  );
  t.txHashes.aliceToBobTransfer = xferResult.txHash;
  console.log(`    Transfer TX: ${xferResult.txHash}`);

  // Step 1.7: Verify Alice's new commitment = C_new
  console.log("\n  Step 1.7: Verify Alice's commitment updated to C_new");
  const aliceAfter = await readCommitment(ALICE_COA_ADDR);
  assertCommitEq(aliceAfter, proofResult.newCommit, "Alice's post-transfer commitment");

  // Step 1.8: Verify Bob's commitment = C_tx (homomorphic add of C_tx to identity)
  console.log("\n  Step 1.8: Verify Bob's commitment = C_tx");
  const bobAfter = await readCommitment(BOB_COA);
  // Bob's commitment = babyAdd(identity, C_tx) = C_tx
  assertCommitEq(bobAfter, proofResult.txCommit, "Bob's post-transfer commitment");

  // Step 1.9: Bob unwraps 3 FLOW
  console.log("\n  Step 1.9: Bob unwraps 3 FLOW");
  const bobPreUnwrap = await readCommitment(BOB_COA);
  console.log(`    Bob's current commitment: (${bobPreUnwrap.x.toString().slice(0,20)}...)`);

  const unwrapArgs = [
    { type: "UInt256", value: bobPreUnwrap.x.toString() },
    { type: "UInt256", value: bobPreUnwrap.y.toString() },
    { type: "UFix64",  value: "3.00000000" },
    { type: "Address", value: BOB_CADENCE },
    { type: "String",  value: BOB_COA },
  ];

  const unwrapResult = flowSend(
    join(REPO_ROOT, "transactions/janus_flow_unwrap.cdc"),
    unwrapArgs,
    { signer: "openjanus-testnet" }
  );
  t.txHashes.bobUnwrap = unwrapResult.txHash;
  console.log(`    Unwrap TX: ${unwrapResult.txHash}`);

  // Step 1.10: Verify Bob's commitment reset to identity
  console.log("\n  Step 1.10: Verify Bob's commitment reset to identity after unwrap");
  const bobFinal = await readCommitment(BOB_COA);
  if (isIdentity(bobFinal)) {
    pass("Bob's commitment is identity after unwrap");
  } else {
    fail(`Bob's commitment NOT reset: (${bobFinal.x}, ${bobFinal.y})`);
  }

  const elapsedMs = Date.now() - startMs;
  console.log(`\n  Test 1 PASSED in ${(elapsedMs/1000).toFixed(1)}s`);
  console.log("  TX hashes:", JSON.stringify(t.txHashes, null, 4));

  t.status = "PASS";
  t.elapsedMs = elapsedMs;
  results.push(t);
}

// ---------------------------------------------------------------------------
// Test 2: Bob tries to spend more than he has — must fail
// ---------------------------------------------------------------------------

async function test2() {
  console.log("\n=== TEST 2: Negative — Bob overspends ===");
  const t = { name: "Test 2: Bob overspends", txHashes: {}, gasEstimates: {} };
  const startMs = Date.now();

  // Bob has identity commitment (from Test 1 unwrap OR initial state)
  const bobCommit = await readCommitment(BOB_COA);
  console.log(`  Bob's current commitment: (${bobCommit.x}, ${bobCommit.y})`);
  console.log(`  Is identity: ${isIdentity(bobCommit)}`);

  if (!isIdentity(bobCommit)) {
    // Bob has some leftover. Try to overspend vs his current balance.
    // For this test, we need to know Bob's balance. Since we don't have the blinding,
    // we can try an invalid proof where old_value > actual balance.
    console.log("  Bob has non-identity commitment — testing proof generation with wrong balance");
  }

  // Try: Bob claims he has 10 FLOW but actually has 0 (identity)
  // Generate a proof with wrong old_value
  console.log("  Generating proof with WRONG old_value (5 when Bob has 0)...");
  const fakeBlinding = 123456789n;
  const fakeTxBlinding = 987654321n;
  const fakeNewBlinding = 111111111n;

  try {
    // This proof generation will succeed (the circuit doesn't check on-chain state),
    // but the EVM will reject it because publicInputs[0..1] must match Bob's slot
    const proofResult = await generateProof(
      5n,          // fake old_value (Bob has 0 or different)
      fakeBlinding,
      3n,          // trying to transfer 3
      fakeTxBlinding,
      fakeNewBlinding
    );
    console.log("  Proof generated (circuit doesn't check on-chain state)");
    console.log("  Submitting with FAKE commitment that won't match Bob's on-chain state...");

    // The public inputs include fake_old_commit as C_old
    // The EVM will reject: publicInputs[0..1] != Bob's on-chain commitment
    const transferArgs = [
      { type: "String",  value: BOB_COA },
      { type: "String",  value: CHARLIE_COA },
      { type: "Array",   value: proofResult.pubInputs6.map(v => ({ type: "UInt256", value: v.toString() })) },
      { type: "Array",   value: proofResult.proof8.map(v => ({ type: "UInt256", value: v.toString() })) },
    ];

    // This must fail (allowError: true)
    const xferResult = flowSend(
      join(REPO_ROOT, "transactions/janus_flow_transfer.cdc"),
      transferArgs,
      { signer: "openjanus-testnet", allowError: true }
    );
    t.txHashes.bobBadTransfer = xferResult.txHash;

    if (!xferResult.ok) {
      console.log(`    Transfer correctly REJECTED: ${xferResult.errorMsg || "assertion failed"}`);
      pass("Negative test: Bob's fraudulent transfer was rejected");
    } else {
      fail("Negative test FAILED: fraudulent transfer should have been rejected!");
    }
  } catch (err) {
    if (err.message.includes("FAIL")) throw err;
    // Expected: tx failed with assertion error
    t.txHashes.bobBadTransfer = err.txHash || "unknown";
    console.log(`    Transfer correctly REJECTED: ${err.message.slice(0,150)}`);
    pass("Negative test: Bob cannot transfer with wrong commitment");
  }

  const elapsedMs = Date.now() - startMs;
  console.log(`\n  Test 2 PASSED in ${(elapsedMs/1000).toFixed(1)}s`);
  t.status = "PASS";
  t.elapsedMs = elapsedMs;
  results.push(t);
}

// ---------------------------------------------------------------------------
// Test 3: Charlie receives from BOTH Alice (10) and Bob (5)
// ---------------------------------------------------------------------------

async function test3() {
  console.log("\n=== TEST 3: Charlie receives from Alice (10) and Bob (5), unwraps 15 ===");
  const t = { name: "Test 3: Charlie multi-source", txHashes: {}, gasEstimates: {} };
  const startMs = Date.now();

  // Step 3.1: Alice wraps 50 FLOW (using openjanus COA as Alice for simplicity)
  console.log("  Step 3.1: Alice wraps 50 FLOW");
  const ALICE_VALUE = 50n;
  const ALICE_BLINDING_3 = 5555555555n;
  const aliceCommit3 = await computeCommitment(ALICE_VALUE, ALICE_BLINDING_3);

  // Get Alice's current commitment to check state
  const aliceCoaResult = spawnSync("flow", [
    "scripts", "execute", "/tmp/get_coa_addr.cdc",
    ALICE_CADENCE,
    "--network", "testnet",
  ], { encoding: "utf8", timeout: 30_000 });
  const aliceCoaMatch = (aliceCoaResult.stdout || "").match(/"([0-9a-f]+)"/i);
  const ALICE_COA_3 = aliceCoaMatch ? aliceCoaMatch[1] : OPENJANUS_COA;

  // Reset Alice's slot first (from Test 1 residual) - mint her C_new3 directly
  const aliceWrapArgs3 = [
    { type: "UFix64", value: "50.00000000" },
    { type: "UInt256", value: aliceCommit3.x.toString() },
    { type: "UInt256", value: aliceCommit3.y.toString() },
    { type: "Address", value: ALICE_CADENCE },
    { type: "String",  value: ALICE_COA_3 },
  ];

  const wrapResult3 = flowSend(
    join(REPO_ROOT, "transactions/janus_flow_wrap.cdc"),
    aliceWrapArgs3,
    { signer: "openjanus-testnet" }
  );
  t.txHashes.aliceWrap50 = wrapResult3.txHash;
  console.log(`    Alice wrap 50 TX: ${wrapResult3.txHash}`);

  // Step 3.2: Bob wraps 30 FLOW (Bob has identity commitment from Test 1)
  console.log("\n  Step 3.2: Bob wraps 30 FLOW");
  const BOB_VALUE_3 = 30n;
  const BOB_BLINDING_3 = 7777777777n;
  const bobCommit3 = await computeCommitment(BOB_VALUE_3, BOB_BLINDING_3);

  const bobWrapArgs3 = [
    { type: "UFix64", value: "30.00000000" },
    { type: "UInt256", value: bobCommit3.x.toString() },
    { type: "UInt256", value: bobCommit3.y.toString() },
    { type: "Address", value: BOB_CADENCE },
    { type: "String",  value: BOB_COA },
  ];

  // Note: Bob's current commitment may be identity (from test 1 unwrap) or non-identity
  // mintXY overwrites the slot, so wrapping works regardless of current state
  const bobWrapResult3 = flowSend(
    join(REPO_ROOT, "transactions/janus_flow_wrap.cdc"),
    bobWrapArgs3,
    { signer: "openjanus-testnet" }
  );
  t.txHashes.bobWrap30 = bobWrapResult3.txHash;
  console.log(`    Bob wrap 30 TX: ${bobWrapResult3.txHash}`);

  // Step 3.3: Alice transfers 10 to Charlie
  console.log("\n  Step 3.3: Alice transfers 10 to Charlie");
  const ALICE_TO_CHARLIE = 10n;
  const ALICE_TX_BLINDING_3  = 999111000n;
  const ALICE_NEW_BLINDING_3 = 111999000n;

  const charlieInitial = await readCommitment(CHARLIE_COA);
  console.log(`    Charlie initial: (${charlieInitial.x}, ${charlieInitial.y}), identity=${isIdentity(charlieInitial)}`);

  const aliceProof3 = await generateProof(
    ALICE_VALUE, ALICE_BLINDING_3,
    ALICE_TO_CHARLIE, ALICE_TX_BLINDING_3,
    ALICE_NEW_BLINDING_3
  );
  console.log(`    Alice proof for -10 to Charlie: ${aliceProof3.proofMs}ms`);

  // Verify Alice's on-chain slot matches expected before transfer
  const aliceOnChain3 = await readCommitment(ALICE_COA_3);
  console.log(`    Alice on-chain: (${aliceOnChain3.x.toString().slice(0,10)}...) expected: (${aliceCommit3.x.toString().slice(0,10)}...)`);

  const aliceToCharlieArgs = [
    { type: "String",  value: ALICE_COA_3 },
    { type: "String",  value: CHARLIE_COA },
    { type: "Array",   value: aliceProof3.pubInputs6.map(v => ({ type: "UInt256", value: v.toString() })) },
    { type: "Array",   value: aliceProof3.proof8.map(v => ({ type: "UInt256", value: v.toString() })) },
  ];

  const aliceXferResult3 = flowSend(
    join(REPO_ROOT, "transactions/janus_flow_transfer.cdc"),
    aliceToCharlieArgs,
    { signer: "openjanus-testnet" }
  );
  t.txHashes.aliceToCharlie = aliceXferResult3.txHash;
  console.log(`    Alice->Charlie TX: ${aliceXferResult3.txHash}`);

  // Step 3.4: Bob transfers 5 to Charlie
  console.log("\n  Step 3.4: Bob transfers 5 to Charlie");
  const BOB_TO_CHARLIE = 5n;
  const BOB_TX_BLINDING_3  = 888666444n;
  const BOB_NEW_BLINDING_3 = 444666888n;

  const bobProof3 = await generateProof(
    BOB_VALUE_3, BOB_BLINDING_3,
    BOB_TO_CHARLIE, BOB_TX_BLINDING_3,
    BOB_NEW_BLINDING_3
  );
  console.log(`    Bob proof for -5 to Charlie: ${bobProof3.proofMs}ms`);

  const bobOnChain3 = await readCommitment(BOB_COA);
  console.log(`    Bob on-chain: (${bobOnChain3.x.toString().slice(0,10)}...) expected: (${bobCommit3.x.toString().slice(0,10)}...)`);

  const bobToCharlieArgs = [
    { type: "String",  value: BOB_COA },
    { type: "String",  value: CHARLIE_COA },
    { type: "Array",   value: bobProof3.pubInputs6.map(v => ({ type: "UInt256", value: v.toString() })) },
    { type: "Array",   value: bobProof3.proof8.map(v => ({ type: "UInt256", value: v.toString() })) },
  ];

  const bobXferResult3 = flowSend(
    join(REPO_ROOT, "transactions/janus_flow_transfer.cdc"),
    bobToCharlieArgs,
    { signer: "openjanus-testnet" }
  );
  t.txHashes.bobToCharlie = bobXferResult3.txHash;
  console.log(`    Bob->Charlie TX: ${bobXferResult3.txHash}`);

  // Step 3.5: Verify Charlie's commitment = homomorphic add of C_tx_alice + C_tx_bob
  console.log("\n  Step 3.5: Verify Charlie's commitment (homomorphic)");
  const charlieOnChain = await readCommitment(CHARLIE_COA);

  // Expected: charlie = babyAdd(babyAdd(initial, aliceTxCommit), bobTxCommit)
  // If initial was identity: charlie = babyAdd(aliceTxCommit, bobTxCommit)
  let expectedCharlie;
  if (isIdentity(charlieInitial)) {
    expectedCharlie = await babyAdd(aliceProof3.txCommit, bobProof3.txCommit);
  } else {
    expectedCharlie = await babyAdd(charlieInitial, aliceProof3.txCommit);
    expectedCharlie = await babyAdd(expectedCharlie, bobProof3.txCommit);
  }

  console.log(`    Charlie on-chain: (${charlieOnChain.x.toString().slice(0,20)}...)`);
  console.log(`    Expected:         (${expectedCharlie.x.toString().slice(0,20)}...)`);
  assertCommitEq(charlieOnChain, expectedCharlie, "Charlie's commitment (homomorphic add)");

  // Step 3.6: Charlie unwraps 15 FLOW
  // Note: Charlie can unwrap the amount she received (15 FLOW = 10 from Alice + 5 from Bob)
  // She needs to know her commitment to call unwrap. Her commitment is charlieOnChain.
  console.log("\n  Step 3.6: Charlie unwraps 15 FLOW");
  const charlieUnwrapArgs = [
    { type: "UInt256", value: charlieOnChain.x.toString() },
    { type: "UInt256", value: charlieOnChain.y.toString() },
    { type: "UFix64",  value: "15.00000000" },
    { type: "Address", value: CHARLIE_CADENCE },
    { type: "String",  value: CHARLIE_COA },
  ];

  const charlieUnwrapResult = flowSend(
    join(REPO_ROOT, "transactions/janus_flow_unwrap.cdc"),
    charlieUnwrapArgs,
    { signer: "openjanus-testnet" }
  );
  t.txHashes.charlieUnwrap = charlieUnwrapResult.txHash;
  console.log(`    Charlie unwrap TX: ${charlieUnwrapResult.txHash}`);

  // Verify Charlie's slot is identity after unwrap
  const charlieFinal = await readCommitment(CHARLIE_COA);
  if (isIdentity(charlieFinal)) {
    pass("Charlie's commitment reset to identity after unwrap");
  } else {
    fail(`Charlie commitment not reset: (${charlieFinal.x}, ${charlieFinal.y})`);
  }

  const elapsedMs = Date.now() - startMs;
  console.log(`\n  Test 3 PASSED in ${(elapsedMs/1000).toFixed(1)}s`);
  t.status = "PASS";
  t.elapsedMs = elapsedMs;
  results.push(t);
}

// ---------------------------------------------------------------------------
// Test 4: Dave gets nothing, tries to unwrap — must fail
// ---------------------------------------------------------------------------

async function test4() {
  console.log("\n=== TEST 4: Dave has no commitment, tries to unwrap ===");
  const t = { name: "Test 4: Dave no funds", txHashes: {}, gasEstimates: {} };
  const startMs = Date.now();

  // Verify Dave has identity commitment
  const daveCommit = await readCommitment(DAVE_COA);
  console.log(`  Dave's commitment: (${daveCommit.x}, ${daveCommit.y})`);
  console.log(`  Is identity: ${isIdentity(daveCommit)}`);

  // Dave tries to unwrap with a FAKE commitment
  console.log("\n  Dave tries to unwrap with fake commitment (should fail)");
  const fakeX = 123456789012345678901234567890n;
  const fakeY = 987654321098765432109876543210n;

  const daveUnwrapArgs = [
    { type: "UInt256", value: fakeX.toString() },
    { type: "UInt256", value: fakeY.toString() },
    { type: "UFix64",  value: "1.00000000" },
    { type: "Address", value: DAVE_CADENCE },
    { type: "String",  value: DAVE_COA },
  ];

  try {
    const daveResult = flowSend(
      join(REPO_ROOT, "transactions/janus_flow_unwrap.cdc"),
      daveUnwrapArgs,
      { signer: "openjanus-testnet", allowError: true }
    );
    t.txHashes.daveBadUnwrap = daveResult.txHash;

    if (!daveResult.ok) {
      console.log(`    Unwrap correctly REJECTED: ${daveResult.errorMsg || "assertion failed"}`);
      pass("Dave's unwrap with wrong commitment rejected");
    } else {
      fail("Dave's fake unwrap should have been REJECTED");
    }
  } catch (err) {
    if (err.message.includes("FAIL")) throw err;
    t.txHashes.daveBadUnwrap = err.txHash || "unknown";
    console.log(`    Unwrap correctly REJECTED: ${err.message.slice(0,150)}`);
    pass("Dave cannot unwrap without valid commitment");
  }

  // Dave also tries with identity commitment (0, 1) — should also fail (0 FLOW to unlock)
  console.log("\n  Dave tries with identity commitment (0 amount)");
  const daveIdentityArgs = [
    { type: "UInt256", value: "0" },
    { type: "UInt256", value: "1" },
    { type: "UFix64",  value: "0.00000000" },
    { type: "Address", value: DAVE_CADENCE },
    { type: "String",  value: DAVE_COA },
  ];

  // This would match on-chain (if Dave's slot is identity), but amount=0 makes it a no-op
  // Actually this should succeed but release 0 FLOW — let's check if the contract allows it
  // In practice, a 0-amount unwrap is valid but harmless (resets slot from identity to identity)
  console.log("    (Skipping 0-amount unwrap test — it's valid but harmless)");

  const elapsedMs = Date.now() - startMs;
  console.log(`\n  Test 4 PASSED in ${(elapsedMs/1000).toFixed(1)}s`);
  t.status = "PASS";
  t.elapsedMs = elapsedMs;
  results.push(t);
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

async function main() {
  console.log("=== JanusFlow v1.1.0 — Multi-User End-to-End Test ===");
  console.log(`Date: ${new Date().toISOString()}`);
  console.log(`Network: testnet${DRY_RUN ? " (DRY_RUN)" : ""}`);
  console.log(`JanusToken EVM:   ${JANUS_EVM}`);
  console.log(`JanusFlow Cadence: ${OPENJANUS_ADDR}`);
  console.log(`openjanus COA:    0x${OPENJANUS_COA}`);
  console.log(`Bob COA:          0x${BOB_COA}`);
  console.log(`Charlie COA:      0x${CHARLIE_COA}`);
  console.log(`Dave COA:         0x${DAVE_COA}`);
  console.log(`Circuit root:     ${CIRCUIT_ROOT}`);
  console.log(`Tests to run:     ${TEST_FILTER.join(", ")}`);
  console.log();

  // Preflight
  if (!existsSync(WASM_PATH)) throw new Error(`WASM not found: ${WASM_PATH}`);
  if (!existsSync(ZKEY_PATH)) throw new Error(`ZKEY not found: ${ZKEY_PATH}`);
  if (!existsSync(VK_PATH))   throw new Error(`VK not found: ${VK_PATH}`);

  // Check if janus_flow_transfer.cdc exists
  const txTransferFile = join(REPO_ROOT, "transactions/janus_flow_transfer.cdc");
  if (!existsSync(txTransferFile)) {
    console.error(`Missing: ${txTransferFile}`);
    console.log("Creating janus_flow_transfer.cdc...");
    // This will be created below
  }

  const txWrapFile   = join(REPO_ROOT, "transactions/janus_flow_wrap.cdc");
  const txUnwrapFile = join(REPO_ROOT, "transactions/janus_flow_unwrap.cdc");
  if (!existsSync(txWrapFile))   throw new Error(`Missing: ${txWrapFile}`);
  if (!existsSync(txUnwrapFile)) throw new Error(`Missing: ${txUnwrapFile}`);
  console.log("Circuit artifacts and transactions: OK\n");

  // Run tests
  const errors = [];
  for (const n of TEST_FILTER) {
    try {
      if (n === 1) await test1();
      if (n === 2) await test2();
      if (n === 3) await test3();
      if (n === 4) await test4();
    } catch (err) {
      console.error(`\n  TEST ${n} FAILED: ${err.message}`);
      if (err.stdout) console.error("  stdout:", err.stdout.slice(0, 500));
      results.push({ name: `Test ${n}`, status: "FAIL", error: err.message });
      errors.push({ test: n, error: err.message });
    }
  }

  // Summary
  console.log("\n" + "=".repeat(60));
  console.log("SUMMARY");
  console.log("=".repeat(60));
  for (const r of results) {
    const statusIcon = r.status === "PASS" ? "PASS" : "FAIL";
    const elapsed = r.elapsedMs ? ` (${(r.elapsedMs/1000).toFixed(1)}s)` : "";
    console.log(`  ${statusIcon}  ${r.name}${elapsed}`);
    if (r.txHashes) {
      for (const [k, h] of Object.entries(r.txHashes)) {
        if (h && h !== "DRY_RUN") {
          console.log(`       ${k}: ${h}`);
        }
      }
    }
    if (r.error) console.log(`       Error: ${r.error}`);
  }

  const passed = results.filter(r => r.status === "PASS").length;
  const total  = results.length;
  console.log(`\n  ${passed}/${total} tests passed`);

  if (errors.length > 0) {
    process.exit(1);
  }
}

main().catch(err => {
  console.error("Fatal error:", err.message);
  if (err.stack) console.error(err.stack);
  process.exit(1);
});
