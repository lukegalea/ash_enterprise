# House style

How this repository writes: docs, ADRs, READMEs, commit messages, code comments, product copy and anything
generated for a reader. Two rules do most of the work: **say the thing first**, and **claim only what is built
and agreed**.

Each rule has a stable id. Tooling that checks writing against these rules cites the id and the line, so change a
rule's wording freely but don't reuse a retired id.

## Shape

**HS-1. Lead with the outcome or the ask.** The first sentence says what happened, what the reader must decide,
or what the thing does. Background comes second, if at all.

**HS-2. Keep it short.** Length is a cost to the reader. Short paragraphs; a table or a list once there are more
than three of anything.

**HS-3. Use plain words.** "We fixed the import by retrying the upload", not "remediation of the ingestion path
was effected". No filler openers, no apologising twice, no exclamation marks.

## Claims

**HS-4. Claim only what is built and proven.** A capability is stated when it exists and something shows it: a
test, a ledger row in [QUESTIONS.md](QUESTIONS.md), a screenshot of the running application. A plan is stated as
a plan, with where it is tracked.

**HS-5. Promise only what someone has agreed to.** No dates, scope or commitments that the person with the
authority hasn't made. When something can't be committed, say so.

**HS-6. No novelty claims.** Don't describe an idea as novel, new, first, unprecedented or something nobody has
done. Say what the design does and why it was chosen. Where prior art helps, cite it neutrally as related work.

**HS-7. Never invent a name, a feature or a date.** Use the names the code and the product already use. Give
dates as dates (`2026-10-17`), not "last week" or "recently".

## Audience

**HS-8. No internal shorthand where a customer or outside contributor reads.** Ticket keys, internal codenames
and team jargon stay out of product copy, public docs and anything sent outside. Spell the thing out.

**HS-9. Product interface copy ships in English and French.** A user-facing string isn't done until it has both.
For other customer-facing writing, check whether a French version is needed rather than assuming English is
enough.

## Where else this is enforced

- Code comments state durable facts about the code. The narrative of how it got there belongs in the commit
  message (Iron Law #26, listed in [AGENTS.md](../AGENTS.md); [IRON-LAWS.md](IRON-LAWS.md) covers how the judge
  runs).
- Decision records follow their own template ([adr/README.md](adr/README.md)); these rules govern how they read.
