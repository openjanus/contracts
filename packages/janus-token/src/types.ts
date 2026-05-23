/**
 * types.ts — Shared types for @openjanus/janus-token SDK
 */

/** A BabyJubJub Pedersen commitment point. Identity = { x: 0n, y: 1n }. */
export interface CommitmentPoint {
  x: bigint;
  y: bigint;
}

/** JanusToken network configuration */
export type JanusNetwork = "testnet" | "mainnet";

/** Underlying token info (present only in WRAPPER mode instances) */
export interface UnderlyingToken {
  /** EVM address of the underlying ERC-20 */
  address: string;
  /** Token symbol (e.g. "FLOW", "USDC") */
  symbol: string;
  /** Token decimals */
  decimals: number;
}

/** Constructor options for JanusToken SDK */
export interface JanusTokenOptions {
  /** Deployed EVM address of the JanusToken contract */
  address: string;
  /** Network to connect to */
  network: JanusNetwork;
  /** Present if this instance is in WRAPPER mode */
  underlying?: UnderlyingToken;
}

/** Deployed addresses by network */
export interface JanusTokenDeployment {
  evm: string;
  cadence: string;
  cadenceContractName: string;
  mode: "NATIVE" | "WRAPPER";
  underlying: string | null;
  primitives: {
    BabyJub: string;
    Groth16Verifier: string;
    PedersenBabyJub_cdc: string;
  };
}

/** Input for generating a confidential transfer proof */
export interface TransferProofInput {
  /** Sender's current balance */
  oldBalance: bigint;
  /** Sender's current blinding factor */
  oldBlinding: bigint;
  /** Amount to transfer */
  transferAmount: bigint;
  /** Blinding factor for the transfer commitment */
  transferBlinding: bigint;
  /** New blinding factor for sender's residual balance */
  newBlinding: bigint;
  /** Path to the circuit WASM file */
  wasmPath: string;
  /** Path to the proving key (.zkey) file */
  zkeyPath: string;
  /** Path to the verification key (optional — enables local verification) */
  vkPath?: string;
}

/** Result of proof generation */
export interface TransferProofResult {
  /** Groth16 proof encoded as uint256[8] (pi_b Fp2-swapped for EIP-197) */
  proof: [bigint, bigint, bigint, bigint, bigint, bigint, bigint, bigint];
  /** Public inputs: [C_old.x, C_old.y, C_tx.x, C_tx.y, C_new.x, C_new.y] */
  publicInputs: [bigint, bigint, bigint, bigint, bigint, bigint];
  /** The three commitment points (for reference) */
  commitments: {
    oldCommit: CommitmentPoint;
    transferCommit: CommitmentPoint;
    newCommit: CommitmentPoint;
  };
  /** True if the proof verified locally before submission */
  locallyVerified: boolean;
}

/** RPC endpoint configuration by network */
export const NETWORK_CONFIG: Record<JanusNetwork, { evmRpc: string; flowAccessApi: string }> = {
  testnet: {
    evmRpc: "https://testnet.evm.nodes.onflow.org",
    flowAccessApi: "https://rest-testnet.onflow.org",
  },
  mainnet: {
    evmRpc: "https://mainnet.evm.nodes.onflow.org",
    flowAccessApi: "https://rest-mainnet.onflow.org",
  },
};

/** Canonical testnet deployment (demo/test instance) */
export const TESTNET_DEPLOYMENT: JanusTokenDeployment = {
  evm: "0x53F49881A1132FF4F674D2c015e35D5B07Fa1F4A",
  cadence: "0x28fef3d1d6a12800",
  cadenceContractName: "JanusToken",
  mode: "NATIVE",
  underlying: null,
  primitives: {
    BabyJub: "0x2c40513b343B70f2A0B7e6Ad6F997DDa819D6f07",
    Groth16Verifier: "0x0085F286d89af79EC59E27CD0c5CcD1c55f42Cf5",
    PedersenBabyJub_cdc: "0x28fef3d1d6a12800",
  },
};
