# ADR 0067 — A document is a pure function of recorded inputs

- **Status:** accepted (2026-11-10); the rendering package is public at `lukegalea/ash_paper`
- **Date:** 2026-11-10
- **Related:** ADR 0040 (record, don't recompute), ADR 0024 (erasure by crypto-shredding), ADR 0038 (models observe, declarations decide), ADR 0068 (the four axes)

## Context

A tenant's document (a notice, a letter, a certificate) is read years after it is issued, by someone who needs to
know what it said and why. Two things go wrong if a document is regenerated from live data: the data has moved, so the
page differs from the one the recipient got; and the layout, wording or engine has moved, so even the same data prints
differently. [ADR 0040](0040-record-dont-recompute.md) states the principle for model answers: what was decided is
recorded once and everything downstream consumes the record. A rendered document is the same kind of thing.

Verified by a spike on 2026-11: Typst 0.15.1, driven through ash_typst 0.6.1, produced byte-identical PDFs across four
runtimes: two container images, two Debian bases limited to one CPU, and a Nix-built Elixir 1.20.3. That held only
after three conditions were met: fonts were vendored and passed explicitly, system fonts were ignored, and the PDF
document id was fixed. Typst warns, and does not error, when a font is missing, so a missing font silently changes the
output unless warnings are treated as failures.

## Decision

**A document is a pure function of recorded inputs.**

    render(layout@h, theme@h, clauses@h[], payload@h ; engine@h, fonts@h) -> bytes@h

`@h` is a content hash. The arguments before the semicolon are the definitions of the document; the two after it are
the environment that must be pinned for the output to be reproducible.

1. **Two frozen inputs.** The *payload* (display strings, already formatted) and the *typed facts* they were formatted
   from are frozen when the document is issued. Display strings allow a re-render. Typed facts allow a later
   requirement to be replayed against what was true at issue.
2. **The stored bytes are the record.** The issued bytes are kept and are what a recipient, an auditor or a court is
   shown. Re-rendering is a check on the record and never a replacement for it.
3. **A lineage snapshot** pins the schema, layout, theme, clause, decision and bundle definitions, plus the engine and
   font hashes, by hash. It carries hashes and references only, never values.
4. **The payload hash is keyed under the subject's erasure scope.** A plain hash of a guessable value (a name, an
   amount, a date) can be brute-forced, so an unkeyed payload hash would leak what erasure removes. Keyed under the
   scope, shredding the key makes the hash unverifiable too.
5. **No model is in the render path.** A model may propose wording or draft a clause for a person to approve (ADR
   0038). Once approved, it is a recorded clause. Nothing at render time calls a model.
6. **Determinism has a boundary.** Re-rendering is digest-equal only within one pinned engine and font set. Across an
   engine or font bump the result is a comparison, reported as such, never an equality claim.
7. **Warnings are failures.** Any compiler warning fails the render.

## Does it consume ActorContext?

Rendering itself takes no actor: it is a pure function over frozen inputs and runs in a worker with no database
access. The surrounding actions (issue, fetch the stored bytes, request a re-render) are ordinary Ash actions under
ordinary policies and tenant scope. The payload is assembled from reads made as the issuing actor, so a document can
never state a fact its issuer could not read.

## Consequences

- A re-render is cheap to verify: compare the digest. A difference points at an input or the environment, and the
  snapshot says which.
- Engine and font upgrades are deliberate events with a comparison report, not silent drift.
- Storage grows with every issued document. That is the price of the record.
- Erasure has a defined behaviour: the keyed hash and the payload fall under the subject's scope; the bytes follow the
  tenant's retention rules for the record.
- Anything that wants "the document as it would read today" is a new document, issued as such.

## Reversal

Allowing a model in the render path means changing decision 5 and giving up digest equality for those documents; the
snapshot would then have to record the model digest, as ADR 0040 requires for any observation. Regenerating instead of
storing bytes means dropping decision 2: the stored column goes, and every audit or dispute answer becomes a re-render
that is only as good as the pinned environment. Both are changes to the render action and the snapshot resource; no
layout, theme or clause needs to change. Existing snapshots keep their hashes and stay verifiable for as long as the
engine and fonts they name remain available.
