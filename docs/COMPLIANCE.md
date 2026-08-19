# Control map

**Read this first.** This is an engineering document describing what the code does, expressed in the
vocabulary an auditor uses. It is **not** an assertion of compliance, and it does not substitute for
an audit.

Roughly half of any real control is not in a repository at all: the policy, the training, the review
cadence, the evidence that a human looked, and the auditor's judgement that all of it operated
continuously over a six-to-twelve-month window. What follows covers the *technical prerequisites* —
the part that is code, and can therefore be pointed at, tested, and shown to have not drifted.

Nothing here is written by hand. Every status is derived from [`docs/QUESTIONS.md`](QUESTIONS.md) by
way of [`docs/controls.json`](controls.json), so a control cannot claim more than the ledger does, and
`mix ash_enterprise.roadmap --check` fails CI if the two ever disagree. That is the same discipline
the roadmap tables use, for the same reason: a compliance page maintained separately from the code is
a compliance page that is wrong.

**A control is scored by its weakest question**, not its average. A control with one open question is
not "mostly satisfied" — it is a control an auditor is going to ask about, and rounding that up would
defeat the purpose of writing this down.

## Where it stands

<!-- roadmap:controls:start -->
### SOC 2 Trust Services Criteria

<sub>2017 criteria, 2022 points of focus</sub>

| Control | What it asks | Where it stands | Bearing on it |
|---|---|---|---|
| **CC6.1** Logical access — authorization | Access to data and systems is restricted to authorized users, and the basis of that authorization is defined. | ⚪ Open — 4/6 shipped<br />The strongest area. Authorization is `(role, privilege, depth)` data evaluated as a pure union with no deny rules, and a conformance suite asserts the resulting truth table rather than a sample of it. The gap is column-level: q6 is open, so 'restricted' is currently a row-level claim only. | `q1` `q2` `q3` `q4` `q5` `q6` |
| **CC6.2** Registration and authorization of new users | Users are registered and authorized before being issued credentials, and access is removed when no longer required. | ⚪ Open — 1/4 shipped<br />Registration and deactivation exist as audited, named actions. Deprovisioning driven by the customer's directory does not — q30 is open, so removal depends on someone here being told. | `q1` `q29` `q30` `q37` |
| **CC6.3** Access is modified and removed on a role change | Access rights are added, modified and removed based on roles, and changes are authorized. | 🟡 Partial — 3/4 shipped<br />A role assignment is an ordinary audited resource, so a grant produces an event naming grantor, grantee and request. Impersonation is attributed but not yet gated (q32). | `q2` `q4` `q37` `q32` |
| **CC7.2** Monitoring — logs are complete and protected | The system is monitored, and log data is protected against alteration. | ⚪ Open — 4/5 shipped<br />Completeness and protection are answered: audit is inherited rather than wired per resource, and the log is hash-chained with a trigger refusing UPDATE and DELETE. Monitoring is not — q38 is open, and 'logs nobody reads' is the classic finding here. | `q7` `q8` `q33` `q34` `q38` |
| **CC7.3** Evaluation of security events | Security events are evaluated to determine whether they represent a failure, and the evaluation is evidenced. | ⚪ Open — 0/3 shipped<br />The weakest area on the board, and it is a process gap rather than a code one: alerts go nowhere, no rota exists, and nothing records that a human looked. | `q38` `q49` `q51` |
| **CC7.4** Incident response | Identified incidents are responded to, contained and communicated. | ⚪ Open — 1/3 shipped<br />The correlation id makes an investigation tractable at 3am — one id reconstructs a whole operation. Nothing makes the investigation start. | `q8` `q49` `q47` |
| **CC8.1** Change management | Changes to infrastructure, data and software are authorized, designed, tested and approved before implementation. | 🟡 Partial — 2/4 shipped<br />Schema change is the strong half: migrations are derived from resources and `mix ash.codegen --check` fails CI on drift, so a schema cannot diverge from the model unnoticed. Approval of changes to *this* system is CI and review, which is evidence an auditor accepts; approval of changes *within* the product is q24 and is stronger. | `q9` `q27` `q43` `q50` |

### ISO/IEC 27001:2022 Annex A

<sub>2022</sub>

| Control | What it asks | Where it stands | Bearing on it |
|---|---|---|---|
| **A.5.15** Access control | Rules for physical and logical access are established based on business and information security requirements. | ✅ Shipped — 4/4 shipped<br />The rules are data, not code — which is what makes them reviewable by someone who does not read Elixir. That is unusually good evidence for this control. | `q2` `q3` `q4` `q5` |
| **A.8.15** Logging | Logs recording activities, exceptions and faults are produced, stored and protected. | ⚪ Open — 4/5 shipped<br />Produced and protected: yes, with a test that tampers to prove it. Stored: q36 is open — nothing expires and nothing is committed to being kept, so the retention half is satisfied by accident. | `q7` `q33` `q34` `q35` `q36` |
| **A.8.16** Monitoring activities | Networks, systems and applications are monitored for anomalous behaviour and appropriate action is taken. | ⚪ Open — 0/3 shipped<br />Telemetry exists and is exported by OpenTelemetry; anomaly detection and action do not. | `q28` `q38` `q47` |
| **A.8.24** Use of cryptography | Rules for the effective use of cryptography, including key management, are defined and implemented. | ⚪ Open — 1/2 shipped<br />Present only where integrity needed it: SHA-256 over the audit chain. Encryption at rest, in transit and key management are the deployment's, and this repository says nothing about them — which is a gap in the map, not a strength. | `q33` `q36` |

### GDPR

<sub>Regulation (EU) 2016/679</sub>

| Control | What it asks | Where it stands | Bearing on it |
|---|---|---|---|
| **Art.15** Right of access | A data subject can obtain confirmation of processing and a copy of their data. | 🔵 Planned — 2/3 shipped<br />For audit data, yes and per tenant. For the subject's own records there is no assembled export — q19 is planned, and a data inventory is the prerequisite. | `q34` `q35` `q19` |
| **Art.17** Right to erasure | A data subject can obtain erasure of their personal data without undue delay. | ⚪ Open — 1/3 shipped<br />The sharpest conflict in the repository, and it got sharper deliberately: soft delete means a destroy is reversible by design, and the audit log now actively refuses DELETE. ADR 0024 resolves it by crypto-shredding rather than by weakening either. Until that ships, this control is unanswered and says so. | `q10` `q14` `q36` |
| **Art.30** Records of processing activities | A controller maintains a record of processing activities, including categories of data and recipients. | ⚪ Open — 1/4 shipped<br />Every processing *event* is recorded in detail; the *register* of activities, categories and recipients is not. q39 is open, and a sub-processor list is the first thing a customer's privacy team asks for. | `q7` `q39` `q40` `q19` |
| **Art.32** Security of processing | Appropriate technical measures ensure ongoing confidentiality, integrity, availability and resilience. | ⚪ Open — 3/5 shipped<br />Confidentiality and integrity are the strong half — tenant isolation is tested to hold even when authorization is wrong, and the log is verifiably intact. Availability and resilience are untested: q48 is open, and an untested restore is a belief rather than a measure. | `q12` `q13` `q33` `q48` `q50` |
<!-- roadmap:controls:end -->

## The honest summary

Three things are unusually well covered, and it is worth saying why rather than leaving it to the
table. **Authorization** (CC6.1, A.5.15) is data rather than code, so it is reviewable by someone who
does not read Elixir, and a conformance suite asserts the whole truth table rather than a sample.
**Log completeness and integrity** (CC7.2, A.8.15) come from audit being inherited rather than wired
per resource — a new table cannot quietly have no history — and from a hash chain a test breaks on
purpose. **Change management of the schema** (CC8.1) is derived from the resources with a `--check`
gate, so a database cannot drift from the model unnoticed.

One area is close to empty, and it is not a coding gap: **evaluation and response** (CC7.3, A.8.16).
Alerts go nowhere, no rota exists, and nothing records that anyone looked. "Logs nobody reads are not
a control" is the standard finding, and it currently applies.

One conflict is structural and deliberate: **erasure** (GDPR Art. 17). Soft delete makes a destroy
reversible by design, and the audit log now actively refuses `DELETE`.
[ADR 0024](adr/0024-audit-retention-and-erasure.md) resolves it by destroying keys rather than rows,
which is a genuine trade-off with a legal reading attached, and is stated as such rather than assumed.

## Gaps this map found

Writing it surfaced two things that were invisible while the questions were only grouped by theme:

- **Evidence of review had no question at all.** It became `q38`, and
  [ADR 0025](adr/0025-log-shipping-and-review.md).
- **Cryptography appears in exactly one place** — SHA-256 over the audit chain. Encryption at rest, in
  transit, and key management are the deployment's, and this repository says nothing about them. That
  is a gap in the map rather than a strength of the system.
