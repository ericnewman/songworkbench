# 01 — Agree the vocal part taxonomy and retire the failed split

Status: needs-triage

## Problem

`ModelCatalog.karaokeVocals` and its refiner are registered, but the checkpoint failed its own
quality gate (it is a vocals-vs-instrumental isolator, not lead/backing). Anyone who installs the
artifact manually gets two stems that both contain the same voice. The catalog's download URL is
`example.invalid`, so it is unreachable to normal users — the wiring is live but the artifact is
not.

## Work

- Decide the part taxonomy from PRD §2 (`lead`, `double`, `harmonyHigh`, `harmonyLow`, optional
  `adlib`) and add the missing `StemID` constants next to `.vocalLead` / `.vocalBacking`.
- Deregister the anvuew refiner (or gate it behind an explicit debug flag) so the app cannot
  present the broken split, keeping the export toolchain and Swift integration intact — per the
  B8 findings, everything except the artifact is reusable.

## Acceptance

- [ ] Taxonomy recorded in `CONTEXT.md`'s glossary (stem set section).
- [ ] No code path can produce `vocals.lead`/`vocals.backing` from the anvuew checkpoint.
- [ ] Test asserts the refiner list for a default Advanced Desktop profile excludes it.
