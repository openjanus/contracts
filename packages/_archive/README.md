# _archive/

This folder contains archived contract packages that have been deprecated and superseded.

## Contents

| Package | Reason Archived | Replacement |
|---------|----------------|-------------|
| [`janus-token-v1/`](./janus-token-v1/) | Pedersen-hash privacy limitation — see DEPRECATED.md | [`../janus-token-v2/`](../janus-token-v2/) |

## Policy

- Archived contracts **remain deployed on-chain** and will not be removed from the chain.
  On-chain contracts are immutable — archiving here is a documentation change only.
- Archived code is preserved for historical reference and backward compatibility research.
- **Do not use archived packages for new development.**
- The deployed addresses are listed in each package's `DEPRECATED.md` as historical reference.

## Migration

For all new development, use `packages/janus-token-v2/`.

See root [CHANGELOG.md](../../CHANGELOG.md) for the full deprecation rationale.
