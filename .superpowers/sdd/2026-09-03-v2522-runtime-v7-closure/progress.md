# SDD ledger — Runtime V7 ABI closure

Plan: `docs/superpowers/plans/2026-09-03-v2522-runtime-v7-closure.md`

## Provenance

- Pre-fix V6 implementation: `148f6ee`.
- Final V6 behavioral fix: `a0c8d71`; evidence: `f38ddff`.
- Successor whole-plan review: FAIL, 0 Critical + 1 Important, solely because the modified CLR retained V6/ABI 6.

## Ruling

Any embedded CLR implementation change requires a new marker, runtime type and ABI integer. Cost if wrong:
long-lived PowerShell processes silently execute an older security/recovery implementation despite importing
new PowerShell source.

## Status

Runtime V7 task: pending. Tasks 5–8 remain blocked.
