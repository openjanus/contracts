/**
 * Type shim for circomlibjs — no official @types package exists.
 *
 * This shim declares only the subset used by @openjanus/janus-token:
 *   buildPedersenHash, buildBabyjub, and the field element type.
 *
 * Field elements (F.e) are opaque objects that F.toObject() converts to bigint.
 * The .e() method may not exist on older builds; use F.e() from the babyJub.F field.
 */
declare module "circomlibjs" {
  export interface FieldElement {
    [key: string]: unknown;
  }

  export interface Field {
    e(val: bigint | number | string): FieldElement;
    toObject(el: FieldElement): bigint;
    add(a: FieldElement, b: FieldElement): FieldElement;
    mul(a: FieldElement, b: FieldElement): FieldElement;
    sub(a: FieldElement, b: FieldElement): FieldElement;
    eq(a: FieldElement, b: FieldElement): boolean;
    isZero(a: FieldElement): boolean;
    p: bigint;
  }

  export interface BabyJub {
    F: Field;
    /** Twisted Edwards point addition */
    addPoint(p1: FieldElement[], p2: FieldElement[]): FieldElement[];
    /** Scalar multiplication */
    mulPointEscalar(p: FieldElement[], s: bigint): FieldElement[];
    /** Pack a point to 32 bytes */
    packPoint(p: FieldElement[]): Uint8Array;
    /** Unpack 32 bytes to a point */
    unpackPoint(buf: Uint8Array): FieldElement[];
    /** Generator points */
    Base8: FieldElement[];
    order: bigint;
    subOrder: bigint;
  }

  export interface PedersenHash {
    hash(buf: Buffer | Uint8Array): Uint8Array;
  }

  export function buildBabyjub(): Promise<BabyJub>;
  export function buildPedersenHash(): Promise<PedersenHash>;
  export function buildMimc7(): Promise<unknown>;
  export function buildMimcSponge(): Promise<unknown>;
  export function buildEddsa(): Promise<unknown>;
  export function buildPoseidon(): Promise<unknown>;
}
