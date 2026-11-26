# Venture Kickoff Report — Dual-Track: SCRD RFP #2637023 + ISC Challenge EN578-24ISC4/100

**Prepared:** November 26, 2026
**Owner:** Luke Galea (CTO)
**For:** Project Manager — kickoff coordination

---

## 1. Mission

Establish a software consultancy on the Palantir model: forward-deployed delivery contracts fund and field-test a reusable product; government grants de-risk the R&D. Two live federal/provincial opportunities dated December 2026 serve as the beachhead. The venture is intended to grow into a governed-AI product company, with the consulting practice as go-to-market engine.

**Success model (Palantir-style):**
- Contract revenue (municipal RFPs) covers initial payroll and generates operational evidence.
- Grant/contract R&D (ISC Phase 2, up to $2M) funds the reusable governance control plane.
- IP stays 100% with the corporation (ISC keeps IP with the bidder).

---

## 2. Target Opportunities

### Track A — SCRD RFP #2637023 (municipal contract revenue)
- **What:** Cross Connection Control Program Development and Backflow Prevention Management System — program design plus software implementation, including three years of system maintenance and support (recurring-revenue tail).
- **Issuer:** Sunshine Coast Regional District (Sechelt, BC), posted on BC Bid.
- **Posted:** ~November 9, 2026. **Closes:** December 8, 2026.
- **Scale estimate:** ~$90K initial engagement plus three-year maintenance tail (analogous Capital Budget Proposal #13).
- **Regulatory context:** SCRD Bylaw No. 425 (cross-connection control); Water Rates and Regulations Bylaw No. 778/2025 (authorized backflow prevention devices); Water Servicing Guidelines v1 (2026).
- **Links:**
  - SCRD bid listing: https://www.scrd.ca/bid-opportunities/cross-connection-control-program-development-and-backflow-prevention-management-system/
  - Document package: BC Bid portal — https://www.bcbid.gov.bc.ca/ (downloadable without registration)
  - Bylaw 425: https://www.scrd.ca/wp-content/uploads/2023/04/425-Cross-Connection-Control-scan.pdf
  - Bylaw 778: https://www.scrd.ca/wp-content/uploads/2026/01/Water-Rates-and-Regulations-No.-778.pdf

### Track B — ISC Challenge EN578-24ISC4/100 (R&D funding)
- **What:** "Artificial Intelligence (AI) decision-making process visibility, traceability and compliance governance" — sponsor: Shared Services Canada, via the Innovative Solutions Canada Challenge Stream (Call 004).
- **Structure:** Phase 2 only. Entry at TRL 5–9; pre-commercial. Up to **$2,000,000**, max **20 months**, no travel required.
- **Closes:** December 22, 2026, 14:00 Eastern (target submission Dec 21).
- **Eligibility:** for-profit; incorporated in Canada; ≤499 FTE including affiliates; R&D in Canada; 50%+ wages in Canada, 50%+ FTEs in Canada, 50%+ senior executives resident in Canada. Applicant must perform ≥50% of Phase 2 work by eligible cost value; subcontractor costs ≤ half of total eligible costs. IP stays with applicant.
- **Scoring:** direct Phase 2 entry requires minimum 65/130 (50%) plus all mandatory Essential Outcomes met (pass/fail).
- **Mandatory Essential Outcomes (paraphrased):**
  1. Continuous alignment of registered AI systems with Canadian regs/policies; identify affected systems; signal reassessment.
  2. Standards-based APIs/connectors (open standards) to exchange registry metadata, assessments, evidence, approvals, decision records.
  3. Access control + data residency/retention/deletion policies manageable without vendor intervention.
  4. Requirements-to-controls mapping with versioned/retirable frameworks; minimum coverage of Policy on Service and Digital, Directive on Automated Decision-Making, AIA, AI Strategy, AI ethics responsibilities.
  5. Human-readable findings naming requirement/evidence/result/confidence; measurable states: met, partially met, not met, n/a, unable to determine.
  6. Reviewer validation/rejection/annotation workflows with full audit logs; assurance artifacts with provenance and RBAC.
  7. Risk/quality assessment of data, models, outputs with baselines, thresholds, traceable outcomes.
- **Links:**
  - Challenge page: https://ised-isde.canada.ca/site/innovative-solutions-canada/en/artificial-intelligence-ai-decision-making-process-visibility-traceability-and-compliance-governance
  - MERX notice: https://www.merx.com/public/supplier/solicitations/notice/22785017762/abstract
  - Call 004 grant instructions: https://ised-isde.canada.ca/site/innovative-solutions-canada/sites/default/files/documents/grant-instructions-procedures-call-04-en-v2.pdf
  - ISC user guide (submission): https://ised-isde.canada.ca/site/innovative-solutions-canada/en/isc-user-guide-proposal-bidders-and-applicants
  - Program eligibility: https://ised-isde.canada.ca/site/innovative-solutions-canada/en/program-eligibility-and-process

---

## 3. Technical Strategy (one codebase, two value propositions)

Built on the in-house template: **github.com/lukegalea/ash_enterprise** (Ash Framework / Phoenix / Elixir enterprise reference app).

- **Domain layer (SCRD):** property/device registry, certified-tester self-service portal, test compliance tracking, hazard-tier risk classification, enforcement workflows (Reactor sagas), reminder engine (Oban), CCCC program documentation outputs.
- **Governance layer (ISC):** AI-system registry; Requirement → Control → Evidence → Finding → ReviewOutcome engine (versioned via temporal_history); audit/correlation from AshEnterprise.Platform.Resource; Marquez/OpenLineage lineage (deploy/marquez.yml); OpenAPI/GraphQL auto-generated from Ash resources.
- **Simulated Use Engine (first-class feature):** deterministic sim tenant (DemoTenant/Seeder/SystemActor already in template) drives realistic municipal operations through the real APIs; 90 days of synthetic operational history pre-loaded. This is the TRL 5–6 evidence for ISC and the live-demo artifact for SCRD.
- **Template rules that apply:** every resource uses AshEnterprise.Platform.Resource (audit/tenancy/soft-delete/policies not optional); no forbid_if for row access; policy checks never query (ActorContext); mix ash.codegen after any resource change; adopt entities from Microsoft CDM corpus via mix cdm.gen.resource (e.g., msdyn_workorder for inspection/test lifecycle).
- **Deployment:** OTP release via Dockerfile; Canadian region (data residency satisfies ISC outcome 3 and pre-empts municipal privacy questions); sim tenant isolated from any future production tenants.

---

## 4. Corporate and Team Structure

- **Applicant/Proponent:** existing consulting corporation (no new entity). Verify the 50% eligibility tests across affiliated corporations; ISC FTE counts include affiliates.
- **Team of 4, award-contingent employment agreements** (employees, not subcontractors — trivially satisfies the applicant-performs-≥50% rule):
  - Luke — CTO / technical lead (month 1 start)
  - Raul — Infrastructure (month 1 start)
  - Ben — Data Science (ramp at month ~4)
  - Riz — Product / BizOps / CEO (ramp at month ~9–10)
- **Delivery-history mitigation:** named CVs with verifiable track records; the running deployed product as corp-history proxy; one advisory name with federal policy gravitas; pilot-interest letters (SCRD response, other municipalities).

### Costing (Option C: ~$220K/yr draw + equity, phased)

| Role | Months | Payroll |
|---|---|---|
| Luke (CTO) | 20 | $366,667 |
| Raul (Infra) | 16 | $293,333 |
| Ben (DS) | 14 | $256,667 |
| Riz (CEO) | 10 | $183,333 |
| **Payroll subtotal** | 60 person-mo | **$1,100,000** |
| Benefits/burden ~15% | | $165,000 |
| Cloud (CDN region), security/pen-test | | $125,000 |
| Legal / IP | | $75,000 |
| **Total** | | **~$1,465,000** |
| Buffer vs $2M ceiling | | ~$535,000 |

Note: 4 × $300K × 20/12 = $2.0M for salaries alone — not viable inside the ceiling; phased $220K is the resolvable shape. Milestone-based ISC disbursements create payroll-bridging gaps — plan consulting revenue bridge or LOC.

---

## 5. Revenue Assumptions (uncounted in the grant ask)

- SCRD-scale win ≈ $90K + 3-year maintenance tail.
- Verified pipeline precedent: City of Barrie "Backflow Program Management Software" RFP (closed Aug 2026); recurring program-support RFPs (Zone 7 Water CA, Paso Robles, DemandStar-posted utilities; MERX shows 963 open BC solicitations).
- Most backflow tenders are physical testing services (not our lane) — tester-service firms are a channel, not competition (undercut BSI Online / SwiftComply incumbents with modern tooling).
- Bid/no-bid filter: software + program-design scope; ≥$75K; no named incumbent; ≥14 days to close.
- Accounting rule: never claim the same hours as both ISC-eligible R&D and customer delivery; confirm Call 004 stacking provisions. Declared pipeline strengthens ISC commercialization-readiness scoring rather than hurting it.
- Market links:
  - Barrie precedent: https://starbridge.ai/rfp/backflow-program-management-software
  - MERX BC: https://www.merx.com/public/solicitations/british-columbia-379
  - BSI Online (incumbent): https://bsionline.ca/

---

## 6. 20-Month Phase 2 Plan (TRL 5→8)

| Gate | Months | Work | Exit criterion |
|---|---|---|---|
| M1 Foundation hardening | 1–3 | De-domain governance engine; multi-tenant prod hardening; RBAC via ActorContext; audit/temporal history as evidence records | TRL 6 demo on non-water data |
| M2 Policy framework engine | 4–7 | Versioned requirements→controls; load TBS baseline (Policy on Service & Digital, DADM, AIA, AI ethics); finding engine w/ confidence scores + five measurable states | Outcomes 1 & 4 demoed |
| M3 Interoperability + human loop | 8–11 | OpenAPI connector framework; evidence ingestion; reviewer validation w/ audit logs; assurance artifact store | Outcomes 2, 3, 5 demoed; TRL 7 pilot prep |
| M4 Operational pilot | 12–16 | Departmental sandbox w/ real AI register; KPIs; security assessment (ITSG-33/SOC 2-aligned) | TRL 7→8 pilot report |
| M5 Productization | 17–20 | Commercialization plan; packaging/pricing; final report + live demo to SSC | TRL 8; Phase 2 final report |

---

## 7. Registration / Admin Workstream

**BC Bid (has a mail step — started Nov 24):**
1. Business BCeID at https://www.bceid.ca/ — activation code mailed to corporate-registry address on file (arrives ~1–2 weeks; 30-day window to activate).
2. BC Bid supplier registration via public portal once BCeID live ( https://www2.gov.bc.ca/gov/content/bc-procurement-resources/bc-bid-resources/bc-bid-for-suppliers ).
3. Confirm RFP #2637023 submission method (e-bid vs hard copy) before paying for e-bidding subscription.
4. Viewing/downloading documents: no account required.
5. If letter not arrived by ~Dec 3: call BC Bid help desk. Follow up: possible BC extra-provincial registration + WorkSafeBC if Ontario-incorporated proponent wins a BC contract.

**ISC portal (fully online, no mail):**
1. Account via Sign-In Partner or GCKey (instant) on the ISC site.
2. Challenge page → "Propose a solution" → submission form (5 sections: applicant info, statistical (voluntary), mandatory eligibility, challenge questions, certification); Phase 2 adds Implementation Team + Financial Submission.
3. Attach proof of Canadian incorporation; authorized officer certifies; keep confirmation email.

---

## 8. Action Checklist

| By | Action | Owner |
|---|---|---|
| Nov 26 | BCeID + BC Bid done/awaiting letter; ISC portal account created; RFP #2637023 package downloaded; confirm submission method + evaluation rubric + Q&A deadline | Luke/PM |
| Nov 27 | Team LOIs + conditional employment agreements drafted (4 named principals); corp eligibility self-test documented | PM/Luke |
| Dec 3 | Chase BC Bid help desk if activation letter absent; checkpoint: TRL demo scope locked | PM |
| Dec 5–7 | Demo deployed on ash_enterprise (registry, tester portal, enforcement reactors, sim tenant w/ 90-day history, governance console, OpenAPI); SCRD proposal frozen Dec 7 | Luke/Raul |
| Dec 8 | Submit RFP #2637023 (courier buffer if hard copy; validate e-bid before deadline) | PM |
| Dec 9–18 | ISC drafting: essential-outcomes-to-feature mapping, TRL justification w/ timestamped artifacts, 20-month plan + budget, Implementation Team section, commercialization plan | ALL |
| Dec 18–20 | Internal pass/fail review vs every mandatory Essential Outcome; self-score ≥65/130; remediate | Riz/Luke |
| Dec 21 | Submit ISC proposal (deadline is Dec 22 14:00 ET — never portal-day) | PM |

---

## 9. Risk Register

| Risk | Mitigation |
|---|---|
| BCeID letter delays past Dec 5 | Incorporation number + access code path completes online; help desk escalation; hard-copy submission fallback if RFP permits |
| TRL 5 claim rejected at ISC | Timestamped, externally visible deployed demo; sim tenant audit history as dated evidence; conservative TRL 5 (not 6) claim |
| ISC competition vs established vendors | Senior named team with verifiable CVs; advisory board name; pilot letters; consider parallel ISC Testing Stream filing when it opens |
| Cash-flow between milestone releases | Founder deferral schedule; consulting revenue bridge; LOC against award agreement |
| Stacking/double-funding audit | Separate cost codes per work item; timesheet discipline; commercial revenue excluded from eligible-cost base |
| Corp has no delivery history | Product artifact + individual track records; land one municipal win in 2027 to establish record |
| SCRD package unread to date | First action Nov 26: download from BC Bid and re-scope assumptions |

---

**Next step:** PM owns Section 8 checklist and the Dec 7/Dec 21 submission freezes; Luke owns architecture and demo budget; confirm sprint staffing for Nov 30 kickoff.
