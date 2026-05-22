# Why "Janus"

## The god

Janus (Latin: *Ianus*) is the Roman god of beginnings, transitions, time, duality, doorways, passages, and endings. He is one of the most ancient Roman gods, with no clear Greek equivalent — purely Roman in origin.

He is always depicted with **two faces**: one looking toward the past, one toward the future. He sees both directions simultaneously because he stands at every threshold.

He presided over:
- The beginning of each day, month, and year (January is named for him)
- The start of planting and harvest seasons
- Births and deaths — the threshold of life
- The gates of war and peace (his temple doors opened during war, closed in peace)
- Every physical doorway, arch, and passage

The phrase "Janus-faced" captures his essence: looking both ways at once, holding two truths simultaneously.

## Why Janus maps onto this token

JanusToken is **dual-faced** in exactly the sense Janus embodies:

**Face 1 — Flow EVM (past/foundation)**
The Solidity contract lives in Flow EVM: BN254 curve math, Groth16 proofs, commitment storage, EIP-197 ecPairing. This is the bedrock — ancient, well-understood, cryptographically sound.

**Face 2 — Cadence (future/access)**
The Cadence wrapper is how Flow-native apps interact: typed resources, capability-based security, atomic cross-VM transactions. This is where Flow's unique value lives.

JanusToken stands at the **threshold between these two worlds**. It is not purely an EVM token or purely a Cadence token — it is both simultaneously.

Like the doors of Janus's temple in the Forum: when a confidential transfer happens, the EVM state changes atomically with the Cadence wrapper call. Both sides of the door open together.

## The openjanus naming system

The broader `@openjanus` package naming convention follows Roman deities associated with **thresholds, transitions, and keys**:

- **Janus** — god of doorways and beginnings → `JanusToken`
- **Cardea** — goddess of door hinges (the pivot point) → `CardeaVault`
- **Portunus** — god of keys, ports, harbors → `PortunusKey`
- **Limen** — personification of thresholds → `LimenBridge`
- **Hekate** — goddess of crossroads → `HekateMixer`

Each name is chosen because the deity's domain describes the contract's architectural role, not just its function. This makes the naming memorable and internally consistent.

## The "janus-token" package name

Package names use the pattern `@openjanus/<deity-name>-<type>`:

- `@openjanus/janus-token` — the token contract
- `@openjanus/cardea-vault` — (future) the vault contract
- `@openjanus/hekate-mixer` — (future) the mixer contract

The prefix `@openjanus` serves as the namespace. `openjanus` itself references Janus: the "open Janus" is the open door, the open threshold — an open-source toolkit for crossing between Cadence and EVM.
