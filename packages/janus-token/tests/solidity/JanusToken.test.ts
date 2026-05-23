/**
 * JanusToken — Hardhat unit tests
 *
 * Tests both NATIVE mode and WRAPPER mode using mock contracts.
 *
 * Test strategy:
 *   - MockVerifier: controls verifyProof return value — isolates state machine from ZK
 *   - MockBabyJub: real BabyJubJub arithmetic via modexp precompile — deterministic vectors
 *   - NATIVE mode tests: T1-T10 (core commitment algebra + access control)
 *   - WRAPPER mode tests: T11-T14 (wrap/unwrap + transfer through wrapper)
 *
 * BabyJubJub identity: (0, 1)
 */

import { expect } from "chai";
import { ethers } from "hardhat";
import { JanusToken, MockBabyJub, MockVerifier } from "../../typechain-types";

// ---------------------------------------------------------------------------
// BabyJubJub curve constants (BN254 scalar field)
// ---------------------------------------------------------------------------
const P = BigInt("21888242871839275222246405745257275088548364400416034343698204186575808495617");

// Generator point BASE8 (circomlib Pedersen base, used for test vectors)
const G_X = BigInt("5299619240641551281634865583518297030282874472190772894086521144482721001553");
const G_Y = BigInt("16950150798460657717958625567821834550301663161624707787222815936182638968203");

// 2G = G + G
const G2_X = BigInt("10031262171927540148667355526369034398030886437092045105752248699557385197826");
const G2_Y = BigInt("633281375905621697187330766174974863687049529291089048651929454608812697683");

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function mockProof(): [bigint, bigint, bigint, bigint, bigint, bigint, bigint, bigint] {
  return [1n, 2n, 3n, 4n, 5n, 6n, 7n, 8n];
}

function buildPublicInputs(
  cOld: [bigint, bigint],
  cTx: [bigint, bigint],
  cNew: [bigint, bigint]
): [bigint, bigint, bigint, bigint, bigint, bigint] {
  return [cOld[0], cOld[1], cTx[0], cTx[1], cNew[0], cNew[1]];
}

// ---------------------------------------------------------------------------
// NATIVE mode test suite
// ---------------------------------------------------------------------------

describe("JanusToken — NATIVE mode", function () {
  let token: JanusToken;
  let mockBabyJub: MockBabyJub;
  let mockVerifier: MockVerifier;
  let owner: any;
  let alice: any;
  let bob: any;

  beforeEach(async function () {
    [owner, alice, bob] = await ethers.getSigners();

    const BabyJubFactory = await ethers.getContractFactory("MockBabyJub");
    mockBabyJub = (await BabyJubFactory.deploy()) as MockBabyJub;
    await mockBabyJub.waitForDeployment();

    const VerifierFactory = await ethers.getContractFactory("MockVerifier");
    mockVerifier = (await VerifierFactory.deploy(true)) as MockVerifier;
    await mockVerifier.waitForDeployment();

    // Deploy JanusToken in NATIVE mode (underlying = address(0))
    const TokenFactory = await ethers.getContractFactory("JanusToken");
    token = (await TokenFactory.deploy(
      await mockVerifier.getAddress(),
      await mockBabyJub.getAddress(),
      ethers.ZeroAddress  // underlying = 0 => NATIVE mode
    )) as JanusToken;
    await token.waitForDeployment();
  });

  it("T1: isWrapperMode is false", async function () {
    expect(await token.isWrapperMode()).to.be.false;
  });

  it("T2: new account has identity commitment (0, 1)", async function () {
    const commit = await token.balanceOfCommitment(alice.address);
    expect(commit.x).to.equal(0n);
    expect(commit.y).to.equal(1n);
  });

  it("T3: mint adds commitment to recipient", async function () {
    await token.connect(owner).mint(alice.address, { x: G_X, y: G_Y });

    const c = await token.balanceOfCommitment(alice.address);
    expect(c.x).to.equal(G_X);
    expect(c.y).to.equal(G_Y);

    const supply = await token.totalSupplyCommitment();
    expect(supply.x).to.equal(G_X);
    expect(supply.y).to.equal(G_Y);
  });

  it("T4: mintXY adds commitment via flat coords", async function () {
    await token.connect(owner).mintXY(alice.address, G_X, G_Y);
    const c = await token.balanceOfCommitment(alice.address);
    expect(c.x).to.equal(G_X);
    expect(c.y).to.equal(G_Y);
  });

  it("T5: confidentialTransfer updates sender and recipient", async function () {
    await token.connect(owner).mint(alice.address, { x: G_X, y: G_Y });

    const publicInputs = buildPublicInputs([G_X, G_Y], [G_X, G_Y], [0n, 1n]);
    await token.connect(alice).confidentialTransfer(bob.address, publicInputs, mockProof());

    const aliceCommit = await token.balanceOfCommitment(alice.address);
    expect(aliceCommit.x).to.equal(0n);
    expect(aliceCommit.y).to.equal(1n);

    const bobCommit = await token.balanceOfCommitment(bob.address);
    expect(bobCommit.x).to.equal(G_X);
    expect(bobCommit.y).to.equal(G_Y);
  });

  it("T6: invalid proof is rejected", async function () {
    await token.connect(owner).mint(alice.address, { x: G_X, y: G_Y });
    await mockVerifier.setResult(false);

    const publicInputs = buildPublicInputs([G_X, G_Y], [G_X, G_Y], [0n, 1n]);
    await expect(
      token.connect(alice).confidentialTransfer(bob.address, publicInputs, mockProof())
    ).to.be.revertedWith("JanusToken: ZK proof verification failed");
  });

  it("T7: C_old mismatch is rejected", async function () {
    await token.connect(owner).mint(alice.address, { x: G_X, y: G_Y });

    const publicInputs = buildPublicInputs([G2_X, G2_Y], [G_X, G_Y], [0n, 1n]);
    await expect(
      token.connect(alice).confidentialTransfer(bob.address, publicInputs, mockProof())
    ).to.be.revertedWith("JanusToken: C_old mismatch - publicInputs[0..1] must equal sender commitment");
  });

  it("T8: non-owner cannot mint", async function () {
    await expect(
      token.connect(alice).mint(bob.address, { x: G_X, y: G_Y })
    ).to.be.revertedWith("JanusToken: caller is not owner");
  });

  it("T9: burn decreases account commitment", async function () {
    await token.connect(owner).mint(alice.address, { x: G2_X, y: G2_Y });
    await token.connect(owner).burn(alice.address, { x: G_X, y: G_Y });

    const c = await token.balanceOfCommitment(alice.address);
    expect(c.x).to.equal(G_X);
    expect(c.y).to.equal(G_Y);
  });

  it("T10: self-transfer is rejected", async function () {
    await token.connect(owner).mint(alice.address, { x: G_X, y: G_Y });
    const publicInputs = buildPublicInputs([G_X, G_Y], [G_X, G_Y], [0n, 1n]);

    await expect(
      token.connect(alice).confidentialTransfer(alice.address, publicInputs, mockProof())
    ).to.be.revertedWith("JanusToken: cannot transfer to self");
  });

  it("T11: sequential mint + transfer + balanceOf integration flow", async function () {
    await token.connect(owner).mint(alice.address, { x: G_X, y: G_Y });
    expect((await token.balanceOfCommitment(alice.address)).x).to.equal(G_X);

    const publicInputs = buildPublicInputs([G_X, G_Y], [G_X, G_Y], [0n, 1n]);
    await token.connect(alice).confidentialTransfer(bob.address, publicInputs, mockProof());

    expect((await token.balanceOfCommitment(alice.address)).y).to.equal(1n); // identity
    expect((await token.balanceOfCommitment(bob.address)).x).to.equal(G_X);
  });

  it("T12: double mint then transfer half — homomorphic invariant", async function () {
    await token.connect(owner).mint(alice.address, { x: G_X, y: G_Y });
    await token.connect(owner).mint(alice.address, { x: G_X, y: G_Y });

    const after2Mints = await token.balanceOfCommitment(alice.address);
    expect(after2Mints.x).to.equal(G2_X);
    expect(after2Mints.y).to.equal(G2_Y);

    const publicInputs = buildPublicInputs([G2_X, G2_Y], [G_X, G_Y], [G_X, G_Y]);
    await token.connect(alice).confidentialTransfer(bob.address, publicInputs, mockProof());

    const aliceFinal = await token.balanceOfCommitment(alice.address);
    expect(aliceFinal.x).to.equal(G_X);
    expect(aliceFinal.y).to.equal(G_Y);

    const bobFinal = await token.balanceOfCommitment(bob.address);
    expect(bobFinal.x).to.equal(G_X);
    expect(bobFinal.y).to.equal(G_Y);
  });

  it("T13: wrap() is unavailable in NATIVE mode", async function () {
    await expect(
      token.connect(alice).wrap(100n, { x: G_X, y: G_Y })
    ).to.be.revertedWith("JanusToken: operation not available in native mode");
  });
});

// ---------------------------------------------------------------------------
// WRAPPER mode test suite
// ---------------------------------------------------------------------------

describe("JanusToken — WRAPPER mode", function () {
  let token: JanusToken;
  let mockBabyJub: MockBabyJub;
  let mockVerifier: MockVerifier;
  let mockERC20: any;
  let owner: any;
  let alice: any;
  let bob: any;

  beforeEach(async function () {
    [owner, alice, bob] = await ethers.getSigners();

    const BabyJubFactory = await ethers.getContractFactory("MockBabyJub");
    mockBabyJub = (await BabyJubFactory.deploy()) as MockBabyJub;
    await mockBabyJub.waitForDeployment();

    const VerifierFactory = await ethers.getContractFactory("MockVerifier");
    mockVerifier = (await VerifierFactory.deploy(true)) as MockVerifier;
    await mockVerifier.waitForDeployment();

    // Deploy a simple ERC-20 mock for underlying
    const ERC20Factory = await ethers.getContractFactory("MockERC20");
    mockERC20 = await ERC20Factory.deploy();
    await mockERC20.waitForDeployment();

    // Deploy JanusToken in WRAPPER mode
    const TokenFactory = await ethers.getContractFactory("JanusToken");
    token = (await TokenFactory.deploy(
      await mockVerifier.getAddress(),
      await mockBabyJub.getAddress(),
      await mockERC20.getAddress()
    )) as JanusToken;
    await token.waitForDeployment();

    // Give alice 1000 tokens and approve the JanusToken contract
    await mockERC20.mint(alice.address, 1000n);
    await mockERC20.connect(alice).approve(await token.getAddress(), 1000n);
  });

  it("T14: isWrapperMode is true", async function () {
    expect(await token.isWrapperMode()).to.be.true;
  });

  it("T15: wrap() mints commitment and locks underlying", async function () {
    await token.connect(alice).wrap(100n, { x: G_X, y: G_Y });

    const c = await token.balanceOfCommitment(alice.address);
    expect(c.x).to.equal(G_X);
    expect(c.y).to.equal(G_Y);

    // Underlying should have been transferred to the contract
    const contractBalance = await mockERC20.balanceOf(await token.getAddress());
    expect(contractBalance).to.equal(100n);
  });

  it("T16: mint() is unavailable in WRAPPER mode", async function () {
    await expect(
      token.connect(owner).mint(alice.address, { x: G_X, y: G_Y })
    ).to.be.revertedWith("JanusToken: operation not available in wrapper mode");
  });

  it("T17: unwrap() burns commitment and releases underlying", async function () {
    await token.connect(alice).wrap(100n, { x: G_X, y: G_Y });

    const aliceBefore = await mockERC20.balanceOf(alice.address);
    await token.connect(owner).unwrap(alice.address, 100n, { x: G_X, y: G_Y });
    const aliceAfter = await mockERC20.balanceOf(alice.address);

    expect(aliceAfter - aliceBefore).to.equal(100n);
    const c = await token.balanceOfCommitment(alice.address);
    expect(c.x).to.equal(0n);
    expect(c.y).to.equal(1n);
  });

  it("T18: wrap + confidentialTransfer + unwrap full flow", async function () {
    // Alice wraps 100 units
    await token.connect(alice).wrap(100n, { x: G_X, y: G_Y });

    // Alice transfers commitment to bob (MockVerifier accepts all proofs)
    const publicInputs = buildPublicInputs([G_X, G_Y], [G_X, G_Y], [0n, 1n]);
    await token.connect(alice).confidentialTransfer(bob.address, publicInputs, mockProof());

    // Bob now has the commitment
    expect((await token.balanceOfCommitment(bob.address)).x).to.equal(G_X);

    // Owner unwraps for bob (gives bob the underlying back)
    const bobBefore = await mockERC20.balanceOf(bob.address);
    await token.connect(owner).unwrap(bob.address, 100n, { x: G_X, y: G_Y });
    const bobAfter = await mockERC20.balanceOf(bob.address);

    expect(bobAfter - bobBefore).to.equal(100n);
    expect((await token.balanceOfCommitment(bob.address)).y).to.equal(1n);
  });
});
