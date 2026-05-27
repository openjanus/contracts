# MAINNET PREPARATION CHECKLIST

> **Last updated:** 2026-05-27 (v0.4.1 sprint)
> **Maintainer:** opencode (zk-prop)
> **Status:** WORKING DOCUMENT — append entries as new testnet-only code lands.

This document tracks code paths that are SAFE on Flow EVM testnet (chainId 545)
but MUST be removed, gated, or replaced before any mainnet deployment. Each
entry has a deterministic verification step so the pre-mainnet audit can
mechanically confirm the change.

## How to use this file

1. Whenever you add testnet-only debug, recovery, or escape-hatch code, append
   an entry here in the same sprint. The PR that introduces the code MUST
   also touch this file.
2. Mark every source-code location with the banner comment:
   ```
   // !!! TESTNET-ONLY — REMOVE BEFORE MAINNET !!!
   ```
3. The pre-mainnet audit (see `audits-kb/audit-checklist/pre-mainnet-deploy.md`)
   greps for that banner AND walks this file end-to-end. Both must be clear
   before tagging a mainnet release.

---

## TESTNET-ONLY CODE TO REMOVE / GATE BEFORE MAINNET

### 1. JanusToken.sol::adminResetSlot

- **Location:** `packages/janus-token/contracts/solidity/JanusToken.sol` (lines
  195–248 as of 2026-05-27)
- **Cadence wrapper:** `packages/janus-token/contracts/cadence/JanusFlow.cdc::adminResetSlot`
- **CLI tx:** `packages/janus-token/transactions/admin_reset_slot.cdc`
- **Why dangerous:**
  - Admin can zero any user's per-account commitment to identity (0, 1).
  - Side-effect leaks the prior commitment via `AdminSlotReset(user, priorX, priorY)`.
  - BREAKS the homomorphic invariant `totalSupplyCommitment == sum(commitments[a])`
    — totalSupplyCommitment is intentionally NOT updated on reset.
  - Owner key compromise = arbitrary privacy demolition.
- **Current guards:**
  - `onlyOwner` on the Solidity function.
  - `require(block.chainid == FLOW_EVM_TESTNET_CHAIN_ID /* 545 */)` — reverts
    on every chain except Flow EVM testnet.
  - Cadence-side `JanusFlow.adminResetSlot` borrows the `AdminResource` at
    `/storage/janusFlowAdmin` (only the deployer 0x5dcbeb41055ec57e holds it).
- **Action for mainnet:**
  - **OPTION A (recommended):** Remove the function entirely from `JanusToken.sol`
    AND from `JanusFlow.cdc`. Delete `admin_reset_slot.cdc`.
  - **OPTION B (if recovery is still wanted):** Replace with a TIME-LOCKED +
    GOVERNANCE-GATED variant (e.g. 7-day delay + 3-of-5 multisig). The
    homomorphic invariant must be preserved (subtract from
    `totalSupplyCommitment` too).
- **Verification:**
  - `grep -rn "adminResetSlot" packages/janus-token/contracts/` should return 0
    matches in a mainnet build.
  - The deployed proxy's `getCode()` should not expose function selector
    `0x...` (compute the selector hash from the function signature for the
    audit trail).
- **Date added:** 2026-05-27

---

## Additional checks to perform pre-mainnet

The following are NOT tracked individually but MUST be reviewed before a
mainnet tag:

- [ ] All circuits' Groth16 verifying keys re-derived from a fresh, audited
      ceremony (NOT reused from testnet).
- [ ] All Solidity contracts re-deployed to a fresh proxy with a brand-new
      owner key (never reuse the testnet owner COA).
- [ ] All Cadence routers re-deployed to a fresh account (never reuse the
      testnet router address).
- [ ] All `chainid == 545` guards in Solidity are removed or replaced with the
      mainnet chainId (747 for Flow EVM mainnet at time of writing).
- [ ] All hardcoded testnet addresses (e.g. `0x09A3DCa868EcC39360fDe4E22046eCfcbA5b4078`)
      in SDK / contracts / docs are replaced with mainnet equivalents.
- [ ] `grep -rn "!!! TESTNET-ONLY" packages/` returns 0 matches.
- [ ] This document's entries are all marked RESOLVED with the mitigating
      commit hashes.
