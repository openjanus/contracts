/**
 * token.ts — JanusToken SDK class
 *
 * Unified API for interacting with a deployed JanusToken contract.
 * Supports both NATIVE mode (own supply) and WRAPPER mode (wraps ERC-20).
 *
 * Usage — read-only:
 *   const token = new JanusToken({ address: "0x...", network: "testnet" });
 *   await token.connect();
 *   const commit = await token.balanceOfCommitment("0xAlice");
 *
 * Usage — with signing:
 *   const token = new JanusToken({ address: "0x...", network: "testnet" });
 *   await token.connectWithSigner(wallet);
 *   await token.mintXY("0xAlice", cx, cy);
 *
 * Usage — wrapper mode:
 *   const janusFlow = new JanusToken({
 *     address: JANUS_FLOW_ADDRESS,
 *     network: "testnet",
 *     underlying: { address: FLOW_EVM_ADDRESS, symbol: "FLOW", decimals: 8 }
 *   });
 *   await janusFlow.connectWithSigner(wallet);
 *   await janusFlow.wrap(100n, commitPoint);
 */

import { ethers } from "ethers";
import type { CommitmentPoint, JanusTokenOptions, TransferProofInput, TransferProofResult } from "./types";
import { createReadOnlyContract, createSigningContract, createProvider, JANUS_TOKEN_ABI } from "./client";
import { computeCommitment } from "./commit";
import { generateTransferProof } from "./proof";

export class JanusToken {
  private readonly opts: JanusTokenOptions;
  private provider: ethers.JsonRpcProvider | null = null;
  private contract: ethers.Contract | null = null;
  private signer: ethers.Signer | null = null;

  constructor(opts: JanusTokenOptions) {
    this.opts = opts;
  }

  // ---------------------------------------------------------------------------
  // Connection
  // ---------------------------------------------------------------------------

  /** Connect with a read-only provider. Enables all view functions. */
  async connect(): Promise<this> {
    this.provider = createProvider(this.opts.network);
    this.contract = createReadOnlyContract(this.opts.address, this.opts.network);
    return this;
  }

  /** Connect with a signing wallet. Enables state-changing functions. */
  async connectWithSigner(signer: ethers.Signer): Promise<this> {
    this.signer = signer;
    this.contract = createSigningContract(this.opts.address, signer);
    this.provider = createProvider(this.opts.network);
    return this;
  }

  // ---------------------------------------------------------------------------
  // Read functions (require connect() or connectWithSigner())
  // ---------------------------------------------------------------------------

  /** Return the deployed EVM address of this JanusToken instance. */
  get address(): string {
    return this.opts.address;
  }

  /** Return true if this instance is in WRAPPER mode. */
  async isWrapperMode(): Promise<boolean> {
    return this._contract().isWrapperMode();
  }

  /**
   * Return the balance commitment for an address.
   * Identity (0, 1) means zero balance.
   */
  async balanceOfCommitment(account: string): Promise<CommitmentPoint> {
    const [x, y] = await this._contract().balanceOfCommitmentXY(account);
    return { x: BigInt(x.toString()), y: BigInt(y.toString()) };
  }

  /**
   * Return the total supply commitment.
   * Identity (0, 1) means zero total supply.
   */
  async totalSupplyCommitment(): Promise<CommitmentPoint> {
    const result = await this._contract().totalSupplyCommitment();
    return { x: BigInt(result.x.toString()), y: BigInt(result.y.toString()) };
  }

  /**
   * Decrypt a balance given the blinding factor used at mint time.
   * Tries values from 0 to maxValue. Returns null if not found.
   *
   * For production apps: store the (value, blinding) pair off-chain at mint time
   * so you can decrypt in O(1) without search.
   */
  async decryptBalance(
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

  // ---------------------------------------------------------------------------
  // NATIVE mode: mint / burn (requires signer + owner authority)
  // ---------------------------------------------------------------------------

  /**
   * Mint a Pedersen commitment to an address (NATIVE mode only).
   * Caller must be the contract owner.
   *
   * @param to  Recipient EVM address
   * @param cx  Commitment x-coordinate
   * @param cy  Commitment y-coordinate
   */
  async mintXY(to: string, cx: bigint, cy: bigint): Promise<ethers.TransactionReceipt> {
    const tx = await this._signingContract().mintXY(to, cx, cy);
    return tx.wait();
  }

  /**
   * Compute Pedersen commitment and mint it (NATIVE mode only).
   * Returns the commitment point for the caller to store.
   *
   * @param to      Recipient EVM address
   * @param amount  Token amount (must be < 2^64)
   * @param blinding 128-bit blinding factor (store this! needed for future decrypt)
   */
  async mint(
    to: string,
    amount: bigint,
    blinding: bigint
  ): Promise<{ receipt: ethers.TransactionReceipt; commit: CommitmentPoint }> {
    const commit = await computeCommitment(amount, blinding);
    const receipt = await this.mintXY(to, commit.x, commit.y);
    return { receipt, commit };
  }

  /**
   * Burn a Pedersen commitment from an address (NATIVE mode only).
   * Caller must be the contract owner and must know the (amount, blinding) pair.
   */
  async burnXY(from: string, cx: bigint, cy: bigint): Promise<ethers.TransactionReceipt> {
    const tx = await this._signingContract().burnXY(from, cx, cy);
    return tx.wait();
  }

  // ---------------------------------------------------------------------------
  // WRAPPER mode: wrap / unwrap
  // ---------------------------------------------------------------------------

  /**
   * Wrap underlying tokens into a confidential commitment (WRAPPER mode only).
   * Caller must have approved this contract for `amount` of the underlying token.
   *
   * @param amount      Amount of underlying to lock
   * @param commitment  Pedersen commitment = Pedersen(amount, blinding) computed off-chain
   */
  async wrap(amount: bigint, commitment: CommitmentPoint): Promise<ethers.TransactionReceipt> {
    const tx = await this._signingContract().wrap(amount, { x: commitment.x, y: commitment.y });
    return tx.wait();
  }

  /**
   * Unwrap: burn commitment and release underlying tokens (WRAPPER mode, owner only).
   *
   * @param from        Account to burn from
   * @param amount      Amount of underlying to release
   * @param commitment  Commitment to subtract
   */
  async unwrap(
    from: string,
    amount: bigint,
    commitment: CommitmentPoint
  ): Promise<ethers.TransactionReceipt> {
    const tx = await this._signingContract().unwrap(from, amount, { x: commitment.x, y: commitment.y });
    return tx.wait();
  }

  /**
   * Convenience: wrap + transfer in one call sequence.
   * Useful for tip-jar pattern: wrap N tokens, immediately transfer to recipient.
   *
   * @param recipient   EVM address of the tip recipient
   * @param amount      Amount of underlying to tip
   * @param blinding    Blinding for the wrap commitment
   * @param txBlinding  Blinding for the transfer commitment
   * @param newBlinding New blinding for sender after transfer (0 since all sent)
   * @param wasmPath    Circuit WASM path (needed for proof generation)
   * @param zkeyPath    Proving key path
   */
  async tip(
    recipient: string,
    amount: bigint,
    blinding: bigint,
    txBlinding: bigint,
    newBlinding: bigint,
    wasmPath: string,
    zkeyPath: string
  ): Promise<{ wrapReceipt: ethers.TransactionReceipt; transferReceipt: ethers.TransactionReceipt }> {
    const commitment = await computeCommitment(amount, blinding);
    const wrapReceipt = await this.wrap(amount, commitment);

    const proofResult = await generateTransferProof({
      oldBalance: amount,
      oldBlinding: blinding,
      transferAmount: amount,
      transferBlinding: txBlinding,
      newBlinding,
      wasmPath,
      zkeyPath,
    });

    const transferReceipt = await this.confidentialTransfer(
      recipient,
      proofResult.publicInputs,
      proofResult.proof
    );

    return { wrapReceipt, transferReceipt };
  }

  // ---------------------------------------------------------------------------
  // Core: confidentialTransfer (all modes)
  // ---------------------------------------------------------------------------

  /**
   * Execute a confidential transfer.
   *
   * The proof must be generated off-chain with generateTransferProof().
   * The pi_b Fp2 swap is handled automatically by that function.
   *
   * @param to           Recipient EVM address
   * @param publicInputs [C_old.x, C_old.y, C_tx.x, C_tx.y, C_new.x, C_new.y]
   * @param proof        [pA.x, pA.y, pB[0][0], pB[0][1], pB[1][0], pB[1][1], pC.x, pC.y]
   */
  async confidentialTransfer(
    to: string,
    publicInputs: [bigint, bigint, bigint, bigint, bigint, bigint],
    proof: [bigint, bigint, bigint, bigint, bigint, bigint, bigint, bigint]
  ): Promise<ethers.TransactionReceipt> {
    const tx = await this._signingContract().confidentialTransfer(to, publicInputs, proof);
    return tx.wait();
  }

  /**
   * Generate a proof and execute a confidential transfer in one call.
   * Requires circuit WASM + proving key files.
   */
  async proveAndTransfer(
    to: string,
    proofInput: TransferProofInput
  ): Promise<{ receipt: ethers.TransactionReceipt; proofResult: TransferProofResult }> {
    const proofResult = await generateTransferProof(proofInput);
    const receipt = await this.confidentialTransfer(to, proofResult.publicInputs, proofResult.proof);
    return { receipt, proofResult };
  }

  // ---------------------------------------------------------------------------
  // Internal helpers
  // ---------------------------------------------------------------------------

  private _contract(): ethers.Contract {
    if (!this.contract) {
      throw new Error(
        "JanusToken: not connected. Call await token.connect() or await token.connectWithSigner(signer) first."
      );
    }
    return this.contract;
  }

  private _signingContract(): ethers.Contract {
    if (!this.signer || !this.contract) {
      throw new Error(
        "JanusToken: not connected with a signer. Call await token.connectWithSigner(wallet) first."
      );
    }
    return this.contract;
  }
}
