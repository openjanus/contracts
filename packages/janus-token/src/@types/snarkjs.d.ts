/**
 * Type shim for snarkjs — no official @types package exists.
 * Declares only the groth16 subset used by @openjanus/janus-token.
 */
declare module "snarkjs" {
  export interface Groth16Proof {
    pi_a: string[];
    pi_b: string[][];
    pi_c: string[];
    protocol: string;
    curve: string;
  }

  export interface FullProveResult {
    proof: Groth16Proof;
    publicSignals: string[];
  }

  export interface VerificationKey {
    protocol: string;
    curve: string;
    nPublic: number;
    vk_alpha_1: string[];
    vk_beta_2: string[][];
    vk_gamma_2: string[][];
    vk_delta_2: string[][];
    vk_alphabeta_12: string[][][];
    IC: string[][];
  }

  export namespace groth16 {
    function fullProve(
      input: Record<string, unknown>,
      wasmPath: string,
      zkeyPath: string
    ): Promise<FullProveResult>;

    function verify(
      vk: VerificationKey,
      publicSignals: string[],
      proof: Groth16Proof
    ): Promise<boolean>;

    function prove(
      zkeyPath: string,
      witnessPath: string
    ): Promise<{ proof: Groth16Proof; publicSignals: string[] }>;

    function exportSolidityCallData(
      proof: Groth16Proof,
      publicSignals: string[]
    ): Promise<string>;
  }
}
