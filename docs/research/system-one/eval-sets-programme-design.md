# Labelled evaluation sets for judgment families — programme design v1

**Status:** Design v1, for review by the owner (Luke). Not a final standard.
**Scope:** This is the public, fully generic half of the programme design (label schema, protocol, statistics, taxonomy, audit design, split discipline, data-handling rules). The private half — named families, named owners and adjudicators, storage locations, access lists, schedule — is deliberately excluded from this document and lives in the private repo. Until the core package exists, this document lives in `ash_enterprise/docs/research/system-one/`; it later moves to the `ash_judgments` package documentation as the eval-sets topic. It contains no customer names, staff names, or document-specific defect detail.

**Why this programme exists.** A band table may not publish for a family without a calibration run above a minimum n, and calibration must be earned per family on labelled data. Operational review does not produce that data: ordinary review rarely surfaces expert-selected *contradicting* passages, and reviewing only the middle band yields a biased sample. A deliberate labelling programme — blind, double-labelled, adjudicated, with planted hard negatives — is therefore a prerequisite for any auto-admission, and its labelled rows are simultaneously the calibration unit, the regression fixture, and the audit corpus.

---

## 1. Label schema

One row = one human label of one (document, question) pair against a set of evidence atoms. The row references content only by hash and id, never by quotation, so rows can cross zone boundaries as identifiers while the documents stay put.

| Field | Type | Rationale (one line) |
|---|---|---|
| `document_hash` | string (hex digest) | Identifies the source document by content hash; no document text ever enters a label row. |
| `atom_ids` | array of string | The evidence atoms (addressed document fragments) the labeller was shown, so the label is reproducible against a parser version. |
| `predicate` / `question_hash` | string / string (hex digest) | The declared predicate name and the content hash of the exact question version being labelled; the hash is the question's identity, so re-worded questions cannot silently reuse old labels. |
| `label` | enum: `supports \| contradicts \| insufficient \| not_applicable \| wrong_scope` | The evidence-disposition layer only — what the atoms say relative to the predicate — never an admission or rule outcome. `wrong_scope` marks evidence that answers a neighbouring question, not this one. |
| `labeller` | string (identity ref) | Who labelled; needed for κ pairing, guideline attribution, and adjudication routing. |
| `labelled_at` | timestamp (UTC) | Ordering and provenance; labels are observations with a time, not eternal truths. |
| `labeller_confidence` | enum or ordinal (`high \| medium \| low`) | Cheap self-report used to route low-confidence rows to adjudication first; never used as evidence quality in metrics. |
| `adjudicated_by` | string (identity ref), nullable | The named owner who resolved a disagreement; null when the row was never disputed. Every disputed row carries a name. |
| `split` | enum: `calibration \| test \| audit \| optimise` | Which use the row may serve (see §6); assignment happens at ingestion, before any model sees the row. |
| `region` | enum: `ca \| us` (extensible) | Jurisdiction is a first-class dimension; a metric that quietly covers one region is the most common data error. |
| `family` | string | The calibration grouping (a question family); all n-per-family statistics are computed within it. |
| `hard_negative_class` | enum or null (§4) | Marks a deliberately planted or known-hard negative; lets calibration report per-difficulty error rates and prevents a set from being all easy positives. |

Set-level identity: every released version of a set carries an `eval_set_hash` (hash over canonical JSON of its rows). Calibration runs record the hash they consumed, so a band table's lineage names the exact labelled set that earned it.

A JSON Schema for label rows is a follow-on deliverable of this design and is the loader contract for the calibration tooling.

---

## 2. Protocol

**Blind labelling.** The labeller sees the document atoms, the predicate, and the question text. The labeller never sees the model's answer, its probability, its band, or any indication of which items the model got wrong. Anything else anchors the labeller to the model and turns the set into a confirmation of current behaviour rather than a measurement of it.

**Double-labelling.** At least 20% of rows per family, sampled uniformly at random at ingestion, are labelled independently by two labellers. Before a family's set may be used at all, the double-labelled subset must reach Cohen's κ ≥ 0.7 on the disposition label. If it does not, the family's labeller guidelines are revised and the disputed class of items re-labelled; the set is not used in the meantime.

**The κ caveat, stated plainly.** κ depends on prevalence: in a family where 95% of rows are `supports`, κ is compressed toward 0 even when raw agreement is high, and in a skewed-to-unanimous set κ can understate genuine agreement; conversely, balanced artificially-easy sets can overstate it. κ ≥ 0.7 is therefore a gate, not the report. Every agreement report also states: class prevalence in the double-labelled subset, raw percent agreement, and per-class agreement (each class's specific agreement / confusion row). If prevalence is extreme (< 10% for any class present), a prevalence-adjusted statistic (PABAK or Gwet's AC1) is reported alongside κ, and the gate may be read on that statistic with the prevalence stated. What is never allowed: dropping κ in favour of raw agreement without reporting prevalence.

**Adjudication.** Every disagreement in the double-labelled subset goes to a named owner for that family (recorded in `adjudicated_by`). The adjudicator may not be one of the two labellers who disagreed. Adjudicated labels are the labels of record; the pre-adjudication pair is retained for agreement statistics. A running log of adjudication decisions feeds the family's guidelines — recurring disagreement patterns are a guidelines defect, not a labeller defect.

**Labeller guidelines.** One short written guideline per family, containing: the disposition definitions with boundary examples; the decision rule for `insufficient` vs `contradicts` (absence of evidence vs present contrary evidence — these are the two most conflated classes); the family's hard-negative classes (§4) with one worked example each; and the current adjudication precedents. Guidelines are versioned; a guideline revision is a reason to re-label a sample of the family's rows, not to trust old labels silently.

---

## 3. n per family

**The bound being used.** Conformal risk control (CRC; Angelopoulos et al. 2022) for a monotone loss, applied to selective auto-admission. Define the loss for calibration item *i* at threshold λ as `L_i(λ) = 1` if the model auto-admits the item (score ≥ λ) **and** the gold label is not `supports`, else `0` — a non-increasing function of λ. Choose the threshold on the calibration set as

```
λ̂ = inf { λ : ( Σᵢ Lᵢ(λ) + 1 ) / (n + 1) ≤ α }
```

Then, under exchangeability between calibration and deployment data, `E[L(λ̂)] ≤ α` — a distribution-free, finite-sample guarantee on the rate of *wrong auto-admissions per scored item* (the unconditional risk). **Assumptions, stated:** (a) calibration items and deployment items are exchangeable (drawn from the same distribution — broken by prevalence or document-population shift, which is why §5's audit monitor and per-region re-derivation exist); (b) the loss is monotone in the single threshold λ; (c) the threshold is chosen by this quantile rule — searching a grid of thresholds and picking the empirical-risk minimiser voids the bound unless a multiple-testing correction (Learn-then-Test style) is applied; (d) the guarantee is on expectation, marginal over the data distribution, not conditional on each item.

**From unconditional to the number we care about.** The operational target is the error rate *among auto-admitted items* (conditional risk): `P(wrong | admitted) = P(admitted ∧ wrong) / coverage`. To certify conditional error ≤ 2% at a planning coverage of ≥ 80%, set the CRC budget to the unconditional level α = 0.8 × 2% = **1.6%**.

**Worked example.** Target: auto-admit error ≤ 2% at ≥ 80% coverage → α = 0.016. Rearranging the CRC feasibility condition `(e + 1)/(n + 1) ≤ α`, where *e* is the number of errors observed among auto-admitted calibration items:

```
n ≥ (e + 1)/α − 1
```

| Errors tolerated in the calibration run (e) | Minimum calibration n |
|---|---|
| 0 | 62 |
| 1 | 124 |
| 2 | 187 |
| 3 | 249 |
| 4 | 312 |

Read: at n = 187 the family may certify the target only if its calibration run shows **two or fewer** wrong auto-admissions; at n = 249 it may show three. A set that can only certify with *zero* observed errors (n = 62) is not robust — one flipped label in a re-run breaks the certificate — so the design floor is set where e ≥ 2 is tolerable.

**Sanity check of the initial recommendation (≥ 200 pairs per family).** The recommendation **holds, narrowly, as a floor**:

- At n = 200 with the strict conditional reading (α = 0.016): `(e+1)/201 ≤ 0.016` tolerates **e ≤ 2**. Satisfiable, but with no headroom.
- At n = 200 with the unconditional reading (α = 0.02, i.e. conditional ≈ 2.5% at 80% coverage): tolerates e ≤ 3. Comfortable, but certifies a weaker number than the stated target.
- **Recommendation:** keep ≥ 200 as the hard floor per family and set the working target at **250–300**, which buys one to two errors of headroom at the full α = 0.016 reading. Revise with the spike's measured variance and base rates once real calibration runs exist — if observed auto-admit error is near 1%, e stays small and 200 suffices; if it hovers near 2%, the certificate is unreachable at any labelling budget until the question or model improves, which is the bound doing its job.

**Sanity check of ≥ 50 per class that auto-admission touches.** Auto-admission touches `supports` (the admitted class), `contradicts` (the auto-fail band — which per the autonomy decision always receives a human glance, so it is banded but not certified for unreviewed action), and `insufficient` (the abstention driving the review band). The honest statement: **50 per class is estimation-grade, not certification-grade.** With 50 items and zero observed errors, the rule-of-three 95% upper bound on the class error rate is 3/50 = 6% — nowhere near 2%. Fifty per class is sufficient for what per-class counts actually do in a calibration run (reliability bins, per-class precision/recall, class-conditional drift detection); the 2%-at-coverage certificate is carried by the family-level calibration n of ≥ 200–250, dominated by the classes admission touches. Per-class counts should not be presented as certifying anything.

---

## 4. Hard-negative taxonomy

Seven classes, each the shape of an error a plausible-looking document induces. Every family's set plants examples from the classes relevant to it; a set of only easy `supports` items certifies nothing about the failure modes that matter.

| # | Class | Generic example (document-evidence flavour) | Clinic-demo analogue (planted defect) |
|---|---|---|---|
| 1 | Right amount, wrong coverage | The certificate states a $2M limit — under a commercial general liability line, while the required line is professional liability. | Limit present and sufficient in amount, but on the wrong coverage kind for the credential rule. |
| 2 | Right obligation, wrong party | The obligation is fully met on paper, but the named insured is the corporate group, not the individual required to hold it. | Wrong name: licence holder does not match the clinician presenting it. |
| 3 | Aggregate vs per-occurrence | The limit reads "$1,000,000" with "aggregate" as its basis; the requirement is per occurrence. | Aggregate-only limit against a per-claim requirement. |
| 4 | Permission vs obligation | Wording that grants a permission ("the holder may maintain excess coverage where required") read as if it imposes a duty. | A note that endorsements "may be issued on request" read as an endorsement in force. |
| 5 | Exception overriding the main clause | The main clause grants the required coverage; a later endorsement carves out exactly the activity in question. | "Binder pending" wording overriding an in-force appearance of the policy. |
| 6 | Definition resembling an obligation | A definitions block ("'covered services' means those the insured is qualified to perform…") that reads like a coverage promise but only defines scope. | A certificate's definitions section read as a coverage grant. |
| 7 | Exhibit not incorporated | The operative clause references "Schedule B — Endorsements", which is absent, or an attachment is present that the document never incorporates. | An irrelevant attachment standing in for the referenced schedule. |

The clinic-demo synthetic corpus plants these at roughly **30% defect density** across its credential documents, with gold labels per (document, predicate) and a generator script so the corpus is reproducible. Additional planted near-misses in that corpus that belong to no class above — an ambiguous date format (04/10 vs 10/04) and an unsigned signature block — are tagged with their own `hard_negative_class` values rather than forced into the seven; the taxonomy is an enum that may grow, and additions are a schema version change, not a silent edit. In the public package the taxonomy ships exactly as this table: class names and shape descriptions, with generic examples only.

---

## 5. Random audit sampling of auto-admitted facts

Calibration certifies an expectation at a moment; production drifts. Per the programme's answer to middle-band selection bias, random audit sampling of **auto-admitted** facts is mandatory wherever a band table is published.

**Design.** Each audit window (suggest: monthly per family × region), draw a uniform random sample of `m` auto-admitted facts and send them to blind human audit — the auditor sees the evidence packet and predicate, never the model's probability, band, or the fact that the item was auto-admitted (the packet for an admitted item is rendered identically to a review-band packet). Audit labels land in the eval set as `split: audit` rows, changing the `eval_set_hash` and feeding the next calibration run.

**Rate formula and arithmetic.** Exact binomial monitoring against the certified level α₀ = 2%:

- Sample size: `m = 200` per family × region per window (all of them, if fewer than 200 were admitted).
- Alarm rule: alarm if errors ≥ **8**, since `P(Binomial(200, 0.02) ≥ 8) = 0.049 ≤ 0.05` — i.e. a true-rate-at-certificate process produces 8 or more errors in a window only 5% of the time. (7 errors gives p = 0.109, not an alarm.)
- Power, honestly: if the true rate degrades to 4%, one window alarms with probability 0.55; at 5%, 0.79. Two consecutive windows at 4% alarm with probability ≈ 0.80. A slower drift is caught by trend, not a single window.
- On alarm: the band table version for that family is frozen back to review-wide (auto-admission suspended, everything routed to the human lane) pending recalibration; the window's mislabelled rows are adjudicated by the family owner and appended to the eval set; the post-mortem names whether the cause was drift (recalibrate), question defect (new question version, new hash, calibration re-earned) or guideline defect (re-label a sample).

The audit monitor's α₀ is the *certified* level from §3, not a constant: if a family certifies at a different budget, the alarm threshold recomputes from its own α₀ by the same rule (smallest k with `P(Binomial(m, α₀) ≥ k) ≤ 0.05`).

---

## 6. Split discipline

Four splits, assigned at ingestion by uniform random draw before any model or optimiser sees a row:

| Split | Serves | Touched by |
|---|---|---|
| `optimise` | Prompt wording experiments, threshold searches, prompt/instruction optimisers, anything that looks at many variants and picks one | Optimisation loops only |
| `calibration` | The n that earns a band table (§3's bound consumes exactly these rows) | Calibration runs |
| `test` | Held-out verification at publish time; the publish-time verifier's number | Publish-time verification only |
| `audit` | Labels produced by §5's production audits; grows over time | Audit programme |

**Why a separate `optimise` split.** The eval set is the standard, not a training signal. The moment prompt or threshold search is allowed to read calibration or test rows, the certificate stops meaning anything: the threshold is fitted to the very sample that certifies it, and the finite-sample bound's exchangeability assumption is broken by selection. Concretely, the CRC rule in §3 assumes the threshold is set by the quantile rule on calibration data — an optimiser free to probe the calibration set and minimise empirical risk is exactly the multiple-testing violation that voids the guarantee. So all search absorbs into `optimise`; the calibration split is consumed once per calibration run by a fixed rule; the test split is opened only by the publish-time verifier, and only to confirm, never to choose. If an optimiser's winning variant is adopted, the question or prompt revision is a **new question version with a new hash**, and it re-earns calibration on data it never saw — the adoption act is what makes a human its author of record.

Mechanically: rows are split before labelling assignment where possible (so no split's items are systematically easier), split proportions are reported with every calibration run, and moving a row between splits is prohibited — a re-split is a new eval-set version with a new hash.

---

## 7. Data handling

Stated as rules; the private half records the concrete instances (which store, which region, whose access).

1. **No customer data outside the region.** CA and US data stay in their own region, in-region storage, in separate eval sets, with separate calibration runs. A combined metric that silently covers one region is the organisation's most common data error; region is a field on every row and a dimension of every report.
2. **Zone admission is checked on the way in.** Data enters a processing zone only if the zone's declared jurisdiction satisfies the data's residency tag — admission is a property of the pair, not just of egress. Data under a restriction the zone cannot satisfy never enters.
3. **No customer data in transcripts, tickets, or commits.** No document content, customer names, or defect detail in issue trackers, session transcripts, commit messages, or any public repo. Label rows are hash-and-id only (§1) precisely so the *labels* can be discussed while the *content* stays in-region.
4. **PDFs stay unmasked and in-region.** Row-level masking tools mask database rows only, not source documents. PDF-derived eval items therefore remain unmasked and in-region under the privacy decision; masked derivatives would require a separate, explicit decision before they exist.
5. **No copy in any public repo, no hosted-model exposure.** The eval sets are private and in-region. No labelled item, document, or extract is sent to any hosted model. Public package docs (including the document you are reading) carry the generic programme only: schema, protocol, statistics, taxonomy — no families' real wording, no owners' names, no storage locations.
6. **Access list and retention.** Each set names an access list (who can read the store) and a retention rule; both are recorded in the private half. Retention aligns with the erasure-vs-replay posture: label rows reference documents by hash, so a document erasure can tombstone without destroying hash-only replay proofs.
7. **Where the private half lives.** The VendorPM-specific programme document — family names and wording, owners and adjudicators per family, in-region storage for CA and US separately, access lists, labelling schedule and hours — lives in the private repo, is never pushed to any public repository, and confirms in its acceptance that no public copy exists.

---

## Open questions

1. **Labelling capacity at the private side:** who labels, and how many hours per week — is labelling paid time needing approval? (Blocks the schedule; not the design.)
2. **Owners:** each initial family needs a named owner and a named adjudicator (they may not be the same person for a given disagreement). This doc's AC is satisfied by "owner needed" blockers in the private half if names are missing.
3. **Per-tier sets vs per-tier thresholds:** do per-customer risk tiers need separate eval sets, or only separate band tables calibrated on the same set? Working assumption: same set, separate thresholds, revisited once tier-stratified error rates exist.
4. **κ gate on PABAK/AC1:** is the §2 allowance (reading the gate on a prevalence-adjusted statistic when prevalence is extreme) acceptable to the owner, or should κ ≥ 0.7 be literal in all cases?
5. **Optimise split as enum value:** the ticket's schema listed three splits; this design adds `optimise` as a fourth value on the cited split-discipline grounds. Confirm, or else split it out as a separate flag.
6. **Audit window sizing:** m = 200 per family × region per month assumes admission volume supports it. For low-volume families, the window lengthens (all admissions audited until m accumulates) — confirm that trade-off is acceptable.
7. **Zero-error fragility:** for families that cannot reach e ≥ 2 tolerance at the labelling budget (§3), the certificate is unreachable by design; is "no auto-admission for that family" an acceptable standing outcome, or does it trigger question redesign effort first?
8. **n revision:** the ≥200/≥250 numbers are to be re-derived from the spike's measured variance and base rates once real calibration runs exist; this document's arithmetic is the template for that revision, not its substitute.

---

*Sources: F-EVALSET ticket (programme scope and acceptance), SYNTHESIS §2.2 laws 5 and 10, §2.3 disposition layer, §7 q3 (middle-band bias; random audit mandatory), §5 W3 (optimise-split rule); external research §4 (conformal selective prediction with cost-aware deferral — Feb 2026 Sci Reports clinical-triage paper; release-side risk under prevalence shift, arXiv 2605.20956; conformal risk control after Angelopoulos et al.); docs-s1 TR3 (hard-negative taxonomy), C25 (labelling programme rationale), CAL1/CAL5, R12 (regional split); capstone §4 (synthetic corpus, ~30% planted defects, labels.csv).*
