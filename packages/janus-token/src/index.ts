/**
 * @openjanus/janus-token
 *
 * JanusToken — ERC-7984 confidential token standard on Flow.
 * Named after Janus, dual-faced Roman god of thresholds and beginnings.
 *
 * Quick start:
 *   import { JanusToken, TESTNET_DEPLOYMENT } from "@openjanus/janus-token";
 *
 *   const token = new JanusToken({
 *     address: TESTNET_DEPLOYMENT.evm,
 *     network: "testnet"
 *   });
 *   await token.connect();
 *
 *   const commit = await token.balanceOfCommitment("0xYourAddress");
 */

// Main class
export { JanusToken } from "./token";

// Commitment utilities
export {
  computeCommitment,
  addCommitments,
  negateCommitment,
  decryptBalance,
} from "./commit";

// Proof utilities
export { generateTransferProof, formatForOnChain } from "./proof";

// Types
export type {
  CommitmentPoint,
  JanusNetwork,
  JanusTokenOptions,
  JanusTokenDeployment,
  UnderlyingToken,
  TransferProofInput,
  TransferProofResult,
} from "./types";

// Constants
export { TESTNET_DEPLOYMENT, NETWORK_CONFIG } from "./types";

// ABI (for direct ethers.js usage)
export { JANUS_TOKEN_ABI } from "./client";
