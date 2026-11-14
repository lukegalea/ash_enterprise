# Control map

This is an engineering document describing what the code does, expressed in the
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
misrepresent it.

## Where it stands

<!-- roadmap:controls:start -->
### SOC 2 Trust Services Criteria

<sub>2017 criteria, 2022 points of focus</sub>

| Control | What it asks | Where it stands | Bearing on it |
|---|---|---|---|
| **CC6.1** Logical access — authorization | Access to data and systems is restricted to authorized users, and the basis of that authorization is defined. | 🟡 Partial — 4/6 shipped<br />The strongest area. Authorization is `(role, privilege, depth)` data evaluated as a pure union with no deny rules, and a conformance suite asserts the resulting truth table rather than a sample of it. The gap is column-level: q6 is partial, with one field policy on one resource, so 'restricted' is still mostly a row-level claim. | `q1` `q2` `q3` `q4` `q5` `q6` |
| **CC6.2** Registration and authorization of new users | Users are registered and authorized before being issued credentials, and access is removed when no longer required. | ⚪ Open — 1/4 shipped<br />Registration and deactivation exist as audited, named actions. A deactivated user cannot sign in, and a bearer token issued before deactivation stops authenticating; `test/ash_enterprise/accounts/deactivation_test.exs` asserts both. Deprovisioning driven by the customer's directory does not exist — q30 is partial, so removal depends on someone here being told. | `q1` `q29` `q30` `q37` |
| **CC6.3** Access is modified and removed on a role change | Access rights are added, modified and removed based on roles, and changes are authorized. | ✅ Shipped — 4/4 shipped<br />A role assignment is an ordinary audited resource, so a grant produces an event naming grantor, grantee and request. Impersonation is attributed, and a break-glass session gates it behind a reason, a second person's approval and an expiry (q32). | `q2` `q4` `q37` `q32` |
| **CC7.2** Monitoring — logs are complete and protected | The system is monitored, and log data is protected against alteration. | 🟡 Partial — 3/5 shipped<br />Completeness and protection are answered: audit is inherited rather than wired per resource, and the log is hash-chained with a trigger refusing UPDATE and DELETE. Monitoring is partial (q38): each alarm on a declared audited event leaves a review record, but most writes are only logged and the audit log itself does not reach SigNoz yet, so 'logs nobody reads' is still the classic finding here. | `q7` `q8` `q33` `q34` `q38` |
| **CC7.3** Evaluation of security events | Security events are evaluated to determine whether they represent a failure, and the evaluation is evidenced. | 🟡 Partial — 0/3 shipped<br />The weakest area on the board, and it is a process gap rather than a code one: declared alarms each record that a human looked (q38) and an alert opens an incident with a triage task (q49), but no rota exists and nothing wakes anyone. | `q38` `q49` `q51` |
| **CC7.4** Incident response | Identified incidents are responded to, contained and communicated. | ⚪ Open — 1/3 shipped<br />The correlation id makes an investigation tractable at 3am — one id reconstructs a whole operation. An alert that reaches the application opens an incident and a triage task for the On-call role (q49); nothing pages anyone. | `q8` `q49` `q47` |
| **CC8.1** Change management | Changes to infrastructure, data and software are authorized, designed, tested and approved before implementation. | 🟡 Partial — 2/4 shipped<br />Schema change is the strong half: migrations are derived from resources and `mix ash.codegen --check` fails CI on drift, so a schema cannot diverge from the model unnoticed. Approval of changes to *this* system is CI and review, which is evidence an auditor accepts; approval of changes *within* the product is q24 and is stronger. | `q9` `q27` `q43` `q50` |

### ISO/IEC 27001:2022 Annex A

<sub>2022</sub>

| Control | What it asks | Where it stands | Bearing on it |
|---|---|---|---|
| **A.5.15** Access control | Rules for physical and logical access are established based on business and information security requirements. | ✅ Shipped — 4/4 shipped<br />The rules are data, not code — which is what makes them reviewable by someone who does not read Elixir. That is unusually good evidence for this control. | `q2` `q3` `q4` `q5` |
| **A.8.15** Logging | Logs recording activities, exceptions and faults are produced, stored and protected. | 🟡 Partial — 3/5 shipped<br />Produced and protected: yes, with a test that tampers to prove it. Stored: q36 is partial — ninety days hot, then a verified move to an archive, nothing purged before four hundred days; it has not yet run in a deployment we operate. | `q7` `q33` `q34` `q35` `q36` |
| **A.8.16** Monitoring activities | Networks, systems and applications are monitored for anomalous behaviour and appropriate action is taken. | ⚪ Open — 0/3 shipped<br />Telemetry exists and is exported by OpenTelemetry, and SigNoz rules alarm on declared security events in it (q38); anomaly detection does not exist. | `q28` `q38` `q47` |
| **A.8.24** Use of cryptography | Rules for the effective use of cryptography, including key management, are defined and implemented. | 🟡 Partial — 1/2 shipped<br />The application uses cryptography for named jobs: SHA-256 over the audit chain, AES-256-GCM sealing under per-scope keys for crypto-shredding with the keys wrapped by an erasure master key (`AshEnterprise.Erasure.Crypto`), and HMAC-SHA256 for keyed digests and for checking signed provider webhooks. Production forces HTTPS with HSTS and refuses to boot without `ERASURE_MASTER_KEY`. TLS termination, disk encryption and custody of the master key are the deployment's, and no written key-management rule exists here — a gap in the map, not a strength. | `q33` `q36` |

### GDPR

<sub>Regulation (EU) 2016/679</sub>

| Control | What it asks | Where it stands | Bearing on it |
|---|---|---|---|
| **Art.15** Right of access | A data subject can obtain confirmation of processing and a copy of their data. | 🔵 Planned — 2/3 shipped<br />For audit data, yes and per tenant. For the subject's own records there is no assembled export. The data inventory the export needs now exists (q19, `docs/data-inventory.json`: which tables hold personal-looking, sensitive or sealed attributes), but it names no steward and assembles nobody's data. | `q34` `q35` `q19` |
| **Art.17** Right to erasure | A data subject can obtain erasure of their personal data without undue delay. | 🟡 Partial — 0/3 shipped<br />The sharpest conflict in the repository, and it got sharper deliberately: soft delete means a destroy is reversible by design, and the audit log now actively refuses DELETE. ADR 0024 resolves it by crypto-shredding rather than by weakening either. Its erasure half is built (2026-10-12): content from an external connection is sealed under that connection's key, and destroying the key reaches the audit log without breaking the chain. Per-person erasure is partial (q14: names and emails in canonical_people survive a shred) and partitioning is not built (q36), so the control is not met and says so. | `q10` `q14` `q36` |
| **Art.30** Records of processing activities | A controller maintains a record of processing activities, including categories of data and recipients. | ⚪ Open — 0/4 shipped<br />Every processing *event* is recorded in detail. The categories of data and the recipient classes are now a generated register (q19 and q39, `docs/data-inventory.json`), with each egress path's gate or the stated lack of one. Still not here: the register of processing activities with purposes and retention per activity, named controllers or stewards, and a deployment's live sub-processor list, which its owner records. | `q7` `q39` `q40` `q19` |
| **Art.32** Security of processing | Appropriate technical measures ensure ongoing confidentiality, integrity, availability and resilience. | 🟡 Partial — 3/5 shipped<br />Confidentiality and integrity are the strong half — tenant isolation is tested to hold even when authorization is wrong, and the log is verifiably intact. Availability and resilience are thin: q48 is partial — a restore drill runs in CI at seed scale, but no RPO or RTO is committed and it has not run on a deployment's own data. | `q12` `q13` `q33` `q48` `q50` |
<!-- roadmap:controls:end -->

## The honest summary

Three things are unusually well covered: **Authorization** (CC6.1, A.5.15) is data rather than code, so it is
reviewable by someone who does not read Elixir, and a conformance suite asserts the whole truth table rather than a
sample.
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
which is a genuine trade-off with a legal reading attached.

## Who owns each of the 61 criteria

The table above maps the questions in the ledger to named controls. A second, separate list lives in the
same file: `docs/controls.json` has a `criteria` row for each of the 61 SOC 2 Trust Services Criteria (security,
availability, processing integrity, confidentiality and privacy). A row names the class of owner, the role
accountable, and the evidence producer, operating process and test where one exists. It never carries a status.

`mix ash_compliance.controls.check --report` lists every piece a row is still missing, and CI prints that list on
every push. At the last review (2026-11-09) 15 rows had nothing missing and 46 did not: most organizational
rows have no operating process, and most rows have no test. A row with nothing missing says the criterion is
owned and wired to things that exist. It does not say the control operates: no evidence is recorded
against any row yet, so none can be called evidenced. `test/ash_enterprise/compliance/control_file_test.exs` fails
the build if a row points at something that does not exist, a status appears, a criterion goes missing, or the
number of missing pieces grows.

## Gaps this map found

Two gaps became visible only when the questions were mapped to controls:

- **Evidence of review had no question at all.** It became `q38`, and
  [ADR 0025](adr/0025-log-shipping-and-review.md).
- **Cryptography is standard primitives for a few named jobs** — a SHA-256 hash chain over the audit log;
  AES-256-GCM sealing under per-scope keys for crypto-shredding (ADR 0024); HMAC-SHA256 for keyed digests
  (sub-keys of an erasure scope's key, invocation argument digests, master-data assertion digests) and for
  checking signed provider webhooks; bcrypt password hashes; and the signed session tokens and cookies that
  ash_authentication and Phoenix provide. Encryption at rest, in transit, and custody of the master key are
  the deployment's, and this repository says nothing about them. That is a gap in the map rather than a
  strength of the system.
