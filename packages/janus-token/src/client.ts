/**
 * client.ts — Ethers.js client for JanusToken EVM contract
 *
 * Provides a thin ethers.js wrapper around the JanusToken ABI.
 * Used internally by the JanusToken SDK class.
 */

import { ethers } from "ethers";
import type { JanusNetwork } from "./types";
import { NETWORK_CONFIG } from "./types";

/** Minimal ABI for JanusToken — only the methods the SDK calls */
export const JANUS_TOKEN_ABI = [
  // View
  "function balanceOfCommitment(address) view returns (tuple(uint256 x, uint256 y))",
  "function balanceOfCommitmentXY(address) view returns (uint256 x, uint256 y)",
  "function totalSupplyCommitment() view returns (tuple(uint256 x, uint256 y))",
  "function isWrapperMode() view returns (bool)",
  "function underlying() view returns (address)",
  "function owner() view returns (address)",
  "function verifier() view returns (address)",
  "function babyJub() view returns (address)",

  // State-changing (NATIVE mode)
  "function mintXY(address to, uint256 cx, uint256 cy)",
  "function burnXY(address from, uint256 cx, uint256 cy)",

  // State-changing (WRAPPER mode)
  "function wrap(uint256 amount, tuple(uint256 x, uint256 y) amountCommitment)",
  "function unwrap(address from, uint256 amount, tuple(uint256 x, uint256 y) amountCommitment)",

  // State-changing (all modes)
  "function confidentialTransfer(address to, uint256[6] publicInputs, uint256[8] proof)",

  // Events
  "event ConfidentialMint(address indexed to, uint256 new_commit_x, uint256 new_commit_y)",
  "event ConfidentialTransfer(address indexed from, address indexed to)",
  "event ConfidentialBurn(address indexed from, uint256 new_commit_x, uint256 new_commit_y)",
  "event Wrap(address indexed account, uint256 amount, uint256 commit_x, uint256 commit_y)",
  "event Unwrap(address indexed account, uint256 amount, uint256 new_commit_x, uint256 new_commit_y)",
] as const;

/** Create a read-only JanusToken contract instance */
export function createReadOnlyContract(
  address: string,
  network: JanusNetwork
): ethers.Contract {
  const provider = new ethers.JsonRpcProvider(NETWORK_CONFIG[network].evmRpc);
  return new ethers.Contract(address, JANUS_TOKEN_ABI, provider);
}

/** Create a signing JanusToken contract instance */
export function createSigningContract(
  address: string,
  signer: ethers.Signer
): ethers.Contract {
  return new ethers.Contract(address, JANUS_TOKEN_ABI, signer);
}

/** Create a provider for the given network */
export function createProvider(network: JanusNetwork): ethers.JsonRpcProvider {
  return new ethers.JsonRpcProvider(NETWORK_CONFIG[network].evmRpc);
}
