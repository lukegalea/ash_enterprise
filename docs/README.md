# Documentation

Four kinds of document live here, and the difference between them is the point.

| | What it is | Read it when |
|---|---|---|
| [**QUESTIONS.md**](QUESTIONS.md) | The ledger. Every question an enterprise application must answer, our answer, and what proves it. | You want to know what this actually does before reading why. |
| [**ROADMAP.md**](ROADMAP.md) | Where the gaps go, in what order, and what each choice beat. | You want to know where it is heading, or whether a decision was reasoned. |
| [**manifesto/**](manifesto/00-index.md) | The argument. Seven theses, one of which is the honest list of what is missing. | You want to know *why* anything here is shaped the way it is. |
| [**adr/**](adr/README.md) | The decisions. Nineteen records, each with the exit from it. | You disagree with something and want to know what it would cost to change. |
| [**plans/**](plans/README.md) | The specifications. Long-form designs for work that is proposed or partly built. | You are about to build one of them. |
| [**HANDOFF.md**](HANDOFF.md) | The state of play, plus findings that were expensive to discover. | You are picking this up in a new session. Start here. |

`roadmap.json` is the machine-readable source every status table in this repository renders from —
including the ones in the root `README.md`. It is rewritten by `mix ash_enterprise.roadmap` and checked
in CI, so a status cannot be right in one place and wrong in another. Edit the JSON, never a generated
table.

`screenshots/` holds real captures of the running application. Nothing in there is a mockup.

## The three raw transcripts

`AshStrangler.md`, `BPMN.md` and `Strangler Fig Migrations for Postgres Schemas…md` at this level are
**unedited research transcripts**, kept for their citations. Each is explicitly superseded by a
document in `plans/`, and each is wrong in specifics that the plan corrects — `BPMN.md` describes a
different application entirely. Do not treat them as guidance.

## Suggested reading order

If you are evaluating: [QUESTIONS.md](QUESTIONS.md) →
[thesis 7](manifesto/07-what-we-do-not-have.md) → [ROADMAP.md](ROADMAP.md).

If you are building: [HANDOFF.md](HANDOFF.md) → [manifesto](manifesto/00-index.md) theses 1 and 3 →
the relevant skill in `.claude/skills/`.
