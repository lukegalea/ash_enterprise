# ADR 0066 — Paper separates schema, layout, theme and wording

- **Status:** accepted (2026-11-10); the implementation is public at `lukegalea/ash_paper` (MIT)
- **Date:** 2026-11-10
- **Related:** ADR 0065 (a document is a pure function of recorded inputs), ADR 0029 (configuration is tenant data), ADR 0028 (decisions are DMN)

## Context

A document has four things that change for different reasons and are owned by different people: what facts it may
state, how the page is built, how it looks for a tenant, and what the words say in each language. Mixed together (a
template with data lookups, brand colours and sentences in one file) every change needs a developer and every review
needs to read everything. Letting tenants supply templates is worse: markup is code, and tenant-supplied code can read
files, call the clock and reach data it should not.

## Decision

Four independent axes, plus requirements.

1. **Schema** says what facts a kind of document may state. The host declares named read paths; they are checked
   against the resource at compile time and recorded in a lock file. A layout can only ask for a declared name.
2. **Layout** is Typst source owned by the host, reviewed as code, locked by hash. A linter rejects `eval`, `read`,
   `sys`, `datetime.today`, plugins, file access and any import other than the kernel's. Layouts reach data only
   through the kernel's library.
3. **Theme** is tenant data: typed tokens (body and heading fonts from the vendored set, sizes, margins, paper size,
   accent colour), validated on write. A tenant never supplies Typst. Tokens are values passed to the layout, not source.
4. **Wording** is clauses: literal runs and typed holes, per locale. A hole is filled only from the payload. A clause
   with no variant for the document's locale blocks the issue; it is never dropped and never falls back silently.
5. **Requirements** (what a document must contain for a given context) are selected by decision, not by layout, and
   are checked against the schema's facts.
6. **Nothing maps data back into a tenant's own file.** Paper generates documents; it does not edit one a tenant
   already holds.
7. **Format before the payload, structure in Typst.** Values are formatted before they enter the payload: money always
   carries its ISO currency code, is never rounded, and has a strict inverse that parses the string back to the typed
   value. Typst generates structure (tables, lists, page breaks) and never formats data.
8. **Read-back compares per labelled block.** A second compile records each labelled block's position, and its page
   content must be identical to the issued render's, so the positions describe the issued pages. Each block's text is
   then compared with the payload. Page furniture (headers, footers, page numbers) is excluded. Whole-page text
   comparison is wrong: a theme swap can move a page break, and in the spike one table row moved to the next page
   while every block's content was unchanged.
9. **Three outcomes: passed, failed, unmeasured.** A block that cannot be measured is `unmeasured`, and `unmeasured` is
   never counted as a pass.

## Does it consume ActorContext?

The axes are data and code owned by the host. Declaring a schema, layout or clause set, and activating a theme, are
Ash actions under ordinary policies. Schema read paths run as the issuing actor, so the payload contains only what
that actor can read; the kernel adds no authorization model of its own.

## Consequences

- A layout change is a reviewed code change with a new hash; a theme or clause change is tenant data with its own
  audit trail; neither can alter the other's meaning.
- Tenants get brand and wording control without any path to executing anything.
- The block comparison is weaker than a whole-page diff and is stated to be: it proves content per block, not the
  placement of page breaks.
- Adding a locale is a clause task, not a layout task, and is blocked until complete.
- Strict money round-trips mean a document cannot be issued if its figures do not parse back.

## Reversal

Collapsing the axes into one template per document type means merging layout, theme and clauses back into host-owned
files: the lock files and linter go, theme becomes code, and tenants lose self-service wording. The kernel's library
and `ash_paper` can be replaced behind the render function in ADR 0065 without touching issued documents, whose bytes
and snapshots are independent of how they were authored. Allowing tenant-supplied markup is a separate reversal of
decision 3 and would need a sandbox first; the linter's rules are the starting list of what such a sandbox must deny.
