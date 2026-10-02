# System One — Model and Runtime Licence & Provenance Audit (S1-23)

> **Scope note.** This is an **engineering audit of public licence records and provenance, prepared for the repo owner and Legal. It is not legal advice.** Verdicts below are engineering read-offs of public licence texts and registry metadata; counsel should confirm anything marked *unclear* or *blocked*. Every source was checked on **2026-10-02**. Fields that could not be located read exactly `not found (looked: …)` — nothing is inferred.
>
> Internal claims audited against: `docs/adr/0042-in-zone-inference-leaving-the-zone-is-a-disclosure.md` (lines 33–49: Ollaya "Apache-2.0"; "bundled models retain their own licences — a mix of Apache-2.0, MIT and proprietary — which have not yet been audited"), `docs/adr/0038` (line 33), `docs/adr/0039` (lines 37–40), `docs/plans/system-one.md` line 178 (this audit is that line item).

## 0. Blocked or unclear — read this first

| # | Item | Status | Use (a) dev/CI | Use (b) clinic-demo | Use (c) VendorPM prod |
|---|---|---|---|---|---|
| B1 | **`winnow:e4b`** (EldanRing/Winnow-E4B, a Gemma 4 derivative) | **Unclear for (b)/(c)** — weights are Apache-2.0-tagged, but the Gemma base brings Google's *Gemma Prohibited Use Policy*, whose §3.4 prohibits *"Making automated decisions in domains that affect material or individual rights or well-being (e.g., finance, legal, employment, healthcare, housing, insurance, and social welfare)"* — the plain text reaches a clinic triage demo. Training data is **not released**. | OK (synthetic data only) | **Do not use as demo default until resolved** (Ollaya currently recommends it as default — pick `laya`/`decider`/`von` instead) | **Blocked pending resolution** |
| B2 | **`ollaya-dev/nli` licence-tag conflict** | HF export tagged `license:mit`; its declared upstream `MoritzLaurer/ModernBERT-large-zeroshot-v2.0` is tagged `license:apache-2.0`. Both permissive, but the registry metadata is demonstrably unreliable — audit every Ollaya registry tag against upstream before pinning. | OK | OK | OK with upstream-verified tag |
| B3 | **ADR 0042's "mix of Apache-2.0, MIT **and proprietary**"** for Ollaya registry models | No proprietary-licensed model was found in the audited set (every model in scope is Apache-2.0 or MIT). Either the "proprietary" member is outside this list or the claim is stale. ADR wording should be corrected after O-3 is answered. | n/a | n/a | n/a |
| B4 | **`laya:typed-decisions` calibration provenance** (not a licence defect) | Card states the shipped temperature was fitted *"on a slice of the same items it had just trained on … treat its confidence as uncalibrated"* until refit. Relevant to (b)/(c) because ADR 0041 makes bands depend on calibration honesty. | OK | Usable, but do not auto-admit its confidences until recalibrated on our data | Same |
| B5 | **Splash stack platform fit** (operational, not licence) | `incoai/splash` is an *Apple-silicon/Metal* runtime; the Splash-format weights (`incoai/Qwen3.8-27B-Splash`, `.bin` layout) are not the GGUF/ONNX artefacts our other runtimes consume. Licence is clean; the operational question is whether VendorPM production runs Linux. | OK | OK | OK, if the zone's host is Apple silicon or a converter is validated |

**DRAFT questions (drafts only — never sent):**

- **D1 → EldanRing** (via HF discussion on `EldanRing/Winnow-E4B`):
  *"Your card states Winnow-E4B is released under Apache 2.0 and is a fine-tune of Gemma 4 E4B IT. Does use of Winnow-E4B remain subject to Google's Gemma Prohibited Use Policy (in particular §3.4 on automated decisions in domains affecting material or individual rights) as a 'Model Derivative'? Separately: can you describe the composition and sourcing of the private training set (synthetic contrastive decisions, verified labels, teacher distributions), and will the adapter checkpoint ever be released? Is the SHA256SUMS file signed or otherwise attested, and from which Gemma 4 base revision was the fine-tune built?"*
- **D2 → Google / Gemma team** (via Gemma docs feedback):
  *"Gemma 4 weights are published under Apache 2.0 (ai.google.dev/gemma/docs/gemma_4_license), while the Gemma Prohibited Use Policy remains published separately. Is the Prohibited Use Policy a binding condition on users of Apache-2.0-licensed Gemma 4 weights and their derivatives, or a policy statement? Does §3.4 (automated decisions affecting material or individual rights) apply to derivative models such as third-party fine-tunes used in a clinical triage demonstration?"*
- **D3 → Ollaya (ollaya-dev / Mert Cobanov)** (via GitHub issue):
  *"(1) `huggingface.co/ollaya-dev/nli` carries a `license:mit` tag while its declared upstream (`MoritzLaurer/ModernBERT-large-zeroshot-v2.0`) is tagged Apache-2.0 — which is authoritative? (2) Our internal ADR recorded that registry models are 'a mix of Apache-2.0, MIT and proprietary' — which registry models, if any, are proprietary-licensed? (3) Please confirm the `winnow:e4b` tag → `EldanRing/Winnow-E4B` Q8_0 GGUF mapping, the pinned commit and sha256 you verify at pull time, and where that pin is published so it can be independently checked."*
- **D4 → Mapika** (via HF discussion on `Mapika/decider-0.8b`):
  *"The 0.8b card says the training mixture is teacher-generated by Qwen3.5-27B over public tasks. Can you publish the source-task list behind the 1.47M-example mixture, so downstream licence/data-provenance review doesn't have to rely on the teacher model's own provenance alone?"*
- **D5 → incoai** (via HF discussion on `incoai/Qwen3.8-27B-Splash`):
  *"The Splash repo's LICENSE file is the Apache-2.0 text with 'Copyright 2026 Alibaba Cloud'. Please confirm the intended attribution chain (Qwen/Qwen3.8-27B → incoai/Qwen3.8-27B-DFlash2 → Splash 4-bit) and that Inco AI adds no terms of its own to the converted weights."*

## 1. Runtime: Ollaya

*Claimed Apache-2.0 — **verified**. Repository: https://github.com/ollaya-dev/ollaya (GitHub API: `license.spdx_id = "Apache-2.0"`, Rust, created 2026-09-23, homepage ollaya.dev, maintained by Mert Cobanov; independent — README: "Ollaya is an independent project. It is not affiliated with or endorsed by Ollama or TypeSafe"). Checked 2026-10-02.*

- **Licence:** Apache-2.0 (GitHub API `license` field + README "License — Apache-2.0").
- **Commercial use:** Yes — Apache-2.0 §2 grants a royalty-free copyright licence and §3 a patent licence covering "offer to sell, sell".
- **Redistribution:** Code may be redistributed under Apache-2.0 §4. **Ollaya does not distribute model weights**: README, "Weights come from their authors" — "Ollaya publishes only small ONNX graphs, about 3 MB each. These graphs read the original weight files … from the author's Hugging Face repository, pinned to a commit and verified by sha256. Models whose authors publish GGUF files (`winnow`, `jevk5`, `jeb`) run that file itself on llama.cpp. **Ollaya never re-hosts weights.**" (This materially improves the demo/provenance story: the digest chain terminates at the author's own repo.)
- **Attribution duties:** Apache-2.0 §4(a)–(d) — pass on the licence, retain notices, propagate NOTICE files where present.
- **Fine-tune/derivative terms:** Apache-2.0 permits derivatives; Modelfile mechanism (`FROM laya; QUESTIONS …`) creates derived *model configs*, which inherit the upstream model's licence.
- **Training-data disclosure:** n/a (runtime code).
- **Bundled-model licensing mix:** README licence section enumerates per-model owners and licences; every model named there is Apache-2.0 or MIT (`nli:modernbert-large` Apache-2.0; `nli:deberta-v3-large` MIT; llama.cpp MIT; `cygnet` = frozen Gemma 4 12B IT, "the Cygnet recipe is MIT"). **No proprietary-licensed model found in the audited set** (looked: ollaya README Licence section; `huggingface.co/api/models?search=Ollaya` org listing, 2026-10-02 — all 14 `ollaya-dev` exports tagged `license:apache-2.0` or `license:mit`). See B3 for the ADR-0042 discrepancy.
- **Weight provenance:** n/a (delegates to per-model entries below; Ollaya pins upstream commits + sha256 per README).
- **Verdict:** (a) **clear** · (b) **clear** (runtime pulls are use, not distribution; pin the binary — ADR 0042 already requires a pinned version after the v0.6.1–v0.7.3 silent-CPU-fallback episode) · (c) **clear** with pinning.

## 2. Ollaya-served decision models

Registry mapping source: Ollaya README models table + `ollaya-dev` HF exports (`huggingface.co/ollaya-dev`), all checked 2026-10-02.

### 2a. `laya:en` → `convaiinnovations/laya` (root checkpoint; ModernBERT-large, 421M) — Convai Innovations

- **Licence:** Apache-2.0 — HF tag `license:apache-2.0`; card footer "Apache 2.0 · Convai Innovations". Code: `github.com/NandhaKishorM/laya`, Apache-2.0 (GitHub API). Backbone `answerdotai/ModernBERT-large` Apache-2.0 (HF API).
- **Commercial use:** Yes (Apache-2.0); card additionally carries a `commercial-use` tag.
- **Redistribution:** Weights and code both Apache-2.0 — redistributable with §4 conditions.
- **Attribution:** Apache-2.0 §4.
- **Fine-tune/derivative terms:** Apache-2.0; fine-tuning explicitly encouraged and documented (public Kaggle notebook; "Fine-tune for better accuracy").
- **Training-data disclosure:** Partial. Method disclosed (RLCD — "the reward is a strictly proper scoring rule"); eval benchmarks named (MASSIVE, XNLI, typed-decisions). Composition of the base checkpoint's own training corpus: **not found (looked: HF card `convaiinnovations/laya` README, fetched in full 2026-10-02; no training-corpus section for the root checkpoint)**.
- **Weight provenance:** Published by **Convai Innovations** (`convaiinnovations/` HF org; card created 2026-09-18). Digest: revision sha not captured in this audit for the root repo (looked: HF author listing 2026-10-02 — listing records don't carry sha; pin via `huggingface.co/api/models/convaiinnovations/laya` at adoption). Ollaya serves it as an ONNX graph pinned to an upstream commit + sha256 (Ollaya README).
- **Note:** card's Honest Limits — English checkpoint's 512-token context; `noul` label-attraction issue #156; ships over-confident (ECE 0.466 → 0.081 after refit). Relevant to ADR 0039's instrument limits.
- **Verdict:** (a) clear · (b) clear · (c) clear (pin revision; recalibrate on our data).

### 2b. `laya:typed-decisions` → `convaiinnovations/laya-typed-decisions` — Convai Innovations

- **Licence:** Apache-2.0 (HF tag; footer "Apache 2.0 · Convai Innovations"). Matches the internal claim in ADR 0042 ("`laya:typed-decisions` (421M parameters, Apache-2.0)") — **verified**.
- **Commercial use:** Yes (Apache-2.0 + `commercial-use` tag).
- **Redistribution:** Weights Apache-2.0, redistributable.
- **Attribution:** Apache-2.0 §4.
- **Fine-tune/derivative terms:** It *is* a derivative (fine-tuned from `convaiinnovations/laya`); Apache-2.0 governs; recipe and notebook public.
- **Training-data disclosure:** Yes — "Fine-tuned from `convaiinnovations/laya` on the benchmark's 1,200-case training split (6,000 decisions)" of the typed-decisions dataset (card links `LocalLLaMA/typed-decisions`). Calibration caveat recorded at B4.
- **Weight provenance:** Convai Innovations; card created 2026-09-18; 0.766 accuracy on typed-decisions per card and per ADR 0041 (which correctly flags the figure as publisher-sourced).
- **Verdict:** (a) clear · (b) clear, subject to B4 · (c) clear, subject to B4 + pin.

### 2c. `decider` 0.8b / 2b / 4b → `Mapika/decider-0.8b`, `-2b`, `-4b`

- **Licence:** Apache-2.0 on all three (HF tags on the author listing, 2026-10-02; `Mapika/decider-0.8b` card front-matter `license: apache-2.0`). Code: `github.com/Mapika/decider`, Apache-2.0 (GitHub API).
- **Commercial use:** Yes (Apache-2.0).
- **Redistribution:** Weights + code Apache-2.0, redistributable.
- **Attribution:** Apache-2.0 §4.
- **Fine-tune/derivative terms:** Apache-2.0; family trained by Mapika from the Qwen3.5 bases.
- **Base model (Qwen3.5):** `Qwen/Qwen3.5-0.8B-Base` / `-2B-Base` / `-4B-Base`, all tagged `license:apache-2.0` with `license_link` to the repo LICENSE (HF API, 2026-10-02; series created 2026-02-24/28 by Qwen). Fetched base README shows **no additional usage restrictions** — the front-matter Note is technical guidance (artifacts/PEFT), not a licence condition. Training-data disclosure for Qwen3.5: **not found (looked: `huggingface.co/Qwen/Qwen3.5-0.8B-Base/raw/main/README.md`, 2026-10-02 — highlights/architecture only; no dataset disclosure section)**. The ticket's "Apache-2.0 with usage notes" expectation: the only notes found are technical, not restrictions.
- **Training-data disclosure (decider):** Partial — "one epoch … over the full mixture (1.47M examples, 455M tokens)"; teacher is Qwen3.5-27B ("The teacher-written training data comes from Qwen3.5-27B and carries its biases"). Source-task list behind the mixture: **not found (looked: decider-0.8b card README, 2026-10-02)** → D4.
- **Weight provenance:** Published by **Mapika** (HF author; 0.8b created 2026-09-19, 2b 2026-09-16, 4b 2026-09-22). Digests: revision shas not captured in the author listing (pin via HF API per repo at adoption). ADR 0042's claim ("built on Qwen3.5, 0.8b–4b; reads next-token logits for option letters") — **verified** against the card.
- **Verdict:** (a) clear · (b) clear · (c) clear with pin; teacher-provenance question (D4) outstanding for Legal.

### 2d. `winnow:e4b` → `EldanRing/Winnow-E4B` — **priority item, now resolved to "permissive but unclear": see B1**

- **Licence:** Apache-2.0 — HF tag `license:apache-2.0`; card "Credits and license": *"Winnow-E4B is an independent fine-tune by EldanRing of Google DeepMind's Gemma 4 E4B IT, released under Apache 2.0 (ai.google.dev/gemma/docs/gemma_4_license). See LICENSE and NOTICE."* The ticket recorded "licence not recorded anywhere yet" — it **is** on the public record as of 2026-10-02.
- **The chain that makes it unclear:** base `google/gemma-4-E4B-it` is tagged `license:apache-2.0` with `license_link: https://ai.google.dev/gemma/docs/gemma_4_license`; that Google page reproduces **only the Apache-2.0 text** (checked 2026-10-02) — but Google publishes a separate **Gemma Prohibited Use Policy** (ai.google.dev/gemma/prohibited_use_policy; "Last modified: February 21, 2024") whose terms are addressed to "Gemma **or Model Derivatives**" and include §3.4: *"Making automated decisions in domains that affect material or individual rights or well-being (e.g., finance, legal, employment, healthcare, housing, insurance, and social welfare)"*. Whether that policy is a binding condition on Apache-2.0-licensed Gemma 4 weights (Gemma 1–3 tied it to the Gemma Terms; the Gemma 4 licence page does not) is **not determinable from the public record** → D1/D2.
- **Commercial use:** Apache-2.0 permits it; policy §3.4 is use-restriction-shaped, not commercial-restriction-shaped — but see B1.
- **Redistribution:** Weights are GGUFs published by the author; Apache-2.0 permits redistribution with §4 + NOTICE propagation (card ships a NOTICE). The demo doesn't redistribute weights (runtime pull) — Apache/MIT requires nothing extra for use.
- **Attribution:** Apache-2.0 §4 + the card's LICENSE and NOTICE files.
- **Fine-tune/derivative terms:** It *is* a derivative (rank-32/alpha-64 LoRA merged FP32 → Q8_0/BF16 GGUF); Apache-2.0 governs. Inference code `github.com/EldanRing/winnow-inference` is MIT (GitHub API; "builds on llama.cpp and preserves its MIT license").
- **Training-data disclosure:** **Not released — stated on the card:** "The private training set combines synthetic contrastive decisions, verified labels, teacher distributions where appropriate, semantic tasks, and targeted hard cases. **The training data and adapter checkpoint are not released.**" Also: "The public suites were known during targeted data design."
- **Weight provenance:** Published by **EldanRing** (HF; `Winnow-E4B` created 2026-09-24; sibling `Winnow-12B` 2026-09-20). Digests published by the author — card's SHA256SUMS, fetched 2026-10-02:
  ```
  840e3f50e5a9c218727f44e121d1b37cc9e2c3b318c8eb422ba6ef2e27b618a2  gguf/Winnow-E4B-Q8_0.gguf
  53c3e504c061f6a7ce84cb6240d427ac6c630850a2cf93f3c2ee980c8136e7e7  gguf/Winnow-E4B-BF16.gguf
  ddf46c21d7078e95338cfc22306b19b276a29a5ad089023449dd54d4b6170a51  gguf/mmproj-Winnow-E4B.gguf
  ```
  Ollaya's `winnow:e4b` runs the author's Q8_0 GGUF on llama.cpp (Ollaya README) — the ADR-0042 facts (Q8_0, ~9 GB, 8k ctx) match the card's measured 8.56 GiB.
- **Verdict:** (a) **clear** (synthetic-data contract test; pin the sha256 above) · (b) **unclear** — B1; pick another default · (c) **blocked pending D1/D2**.

### 2e. NLI (ticket: "DeBERTa-v3-large based")

Ollaya's registry serves **two** NLI variants; the ticket's description matches `nli:deberta-v3-large`, while the `ollaya-dev/nli` HF export is the ModernBERT one — both recorded:

- **`nli:deberta-v3-large`** — Ollaya README: Moritz Laurer, **MIT**. Upstream fine-tune `MoritzLaurer/DeBERTa-v3-large-mnli-fever-anli-ling-wanli`: `license:mit` (HF API, 2026-10-02). Base `microsoft/deberta-v3-large`: `license:mit`, cardData `license: "mit"` (HF API, 2026-10-02).
- **`nli:modernbert-large`** — upstream `MoritzLaurer/ModernBERT-large-zeroshot-v2.0`: `license:apache-2.0`, base `answerdotai/ModernBERT-large` (Apache-2.0), revision sha `a51e07b524299e309dd2b88d48b0cfa2bd9ec598` (HF API, 2026-10-02). **Conflict:** the `ollaya-dev/nli` export of this model is tagged `license:mit` (B2).
- **Commercial use:** Yes for both (MIT / Apache-2.0). **Redistribution:** both permissive (code-style licences applied to weights). **Attribution:** licence + copyright notice retention. **Fine-tune/derivative terms:** permissive; no additional terms found. **Training-data disclosure:** upstream NLI cards name training suites (mnli/fever/anli/ling/wanli family for the DeBERTa one, per its id and card family); dataset-level composition not audited further (looked: HF API records 2026-10-02 only). **Provenance:** Moritz Laurer (HF author) for both; Ollaya pins upstream commits + sha256.
- **Verdict:** (a) clear · (b) clear · (c) clear after B2 resolved (tag upstream, not the export).

### 2f. `gliclass` → `knowledgator/gliclass-instruct-large-v1.0` — Knowledgator

- **Licence:** Apache-2.0 (HF tag + cardData; revision sha `825e5478c1bf4bffbf297690517097ccbdb2e006`, 2026-10-02). Library code: `github.com/Knowledgator/GLiClass`, Apache-2.0 (GitHub API).
- **Commercial use:** Yes. **Redistribution:** weights + code, Apache-2.0. **Attribution:** §4.
- **Fine-tune/derivative terms:** Apache-2.0; no extra terms found.
- **Training-data disclosure:** cardData lists training datasets (`BioMike/formal-logic-reasoning-gliclass-2k`, `knowledgator/gliclass-v3-logic-dataset`, `tau/commonsense_qa`) plus arXiv:2508.07662. Full mixture composition beyond the listed datasets: **not found (looked: HF API record incl. cardData, 2026-10-02)**.
- **Backbone:** Knowledgator's card declares no `base_model` (looked: HF API record tags + cardData, 2026-10-02); Ollaya README describes GLiClass as "(DeBERTa-v3-large)". `microsoft/deberta-v3-large` is MIT (verified), so the chain is permissive under Ollaya's description; the backbone question itself should be settled from the arXiv paper before production (not blocking under either reading: MIT/Apache both fine).
- **Verdict:** (a) clear · (b) clear · (c) clear with pin.

### 2g. `qwen3guard` → `Qwen/Qwen3Guard-Gen-0.6B` — Qwen team

- **Licence:** Apache-2.0 (HF tag; cardData; base `Qwen/Qwen3-0.6B` finetune, also Apache-2.0; arXiv:2510.14276). Ollaya serves it as the safety guard with built-in questions ("safe, controversial or unsafe, and the category") — matches ADR 0038's safety-rung intent.
- **Commercial use / redistribution / attribution / derivative terms:** Yes / permissive / §4 / Apache-2.0.
- **Training-data disclosure:** Disclosure exists via the referenced paper (arXiv:2510.14276, cited on the model record); dataset composition not verified in this audit (looked: HF API record fields, 2026-10-02; paper not reviewed).
- **Weight provenance:** Published by **Qwen** (Alibaba); created 2025-09-23. Digest: revision sha not captured in the search listing (pin via HF API at adoption).
- **Verdict:** (a) clear · (b) clear · (c) clear with pin.

### 2h. `kev` / `kev:0.8b` → `jaredpalmer/kev-0.8b` — Jared Palmer

- **Licence:** Apache-2.0 (HF tag on `jaredpalmer/kev-0.8b`, created 2026-09-20; LoRA adapter + pointer head on `Qwen/Qwen3.5-0.8B-Base`). Ollaya export `ollaya-dev/kev` tagged `license:apache-2.0`. Ollaya README: "Jared Palmer's Kev: a LoRA and a pointer head on Qwen3.5 (4B by default, 0.8B, 9B), calibrated."
- **Commercial use / redistribution / attribution / derivative terms:** Yes / permissive / §4 / Apache-2.0.
- **Training-data disclosure:** Yes, dataset-level — the card enumerates training datasets (banking77, boolq, ag_news, multi_nli, sst5, yelp_review_full, trec, dbpedia_14, amazon_reviews_multi_en, imdb, commitpackft, nvidia/Aegis-AI-Content-Safety-Dataset-2.0, davidheineman/consumer-finance-complaints-large).
- **Weight provenance:** Published by **Jared Palmer** (HF author record, 2026-10-02); upstream found (the ticket's provenance question resolves). Revision sha not captured in the search listing (pin via HF API at adoption).
- **Note:** the Winnow card's "Kev v9" is the evaluation suite of the same name; distinct from the model weights.
- **Verdict:** (a) clear · (b) clear · (c) clear with pin.

### 2i. `von` → `wfzyx/von` — Victor Hugo Panisa (ticket: "ModernBERT-based" — **confirmed**)

- **Licence:** Apache-2.0 — card: "**License:** Apache-2.0"; revision sha `52dd1845eb625fbaf67e26596df3f347f96a69a2`; lastModified 2026-10-01 (HF API + card README, 2026-10-02).
- **Base:** finetune of `answerdotani/ModernBERT-large` (Apache-2.0, verified) + Option-Marker head; 395M params.
- **Commercial use / redistribution / attribution / derivative terms:** Yes / permissive / §4 / Apache-2.0; no prohibited-use clauses found on the card ("The only restrictions are technical/operational limitations").
- **Training-data disclosure:** Strongest in the set — "~290k-item balanced decision corpus" with per-cluster percentages (operational/enterprise ~25%, security/DevOps ~20%, safety/policy ~15%, linguistic ~15%, triage/services ~10%, adversarial ANLI/WANLI ~15%); "No JevBench item, public or sealed, is used for gradient training"; corpus builders published under `training/` in the repo.
- **Weight provenance:** Published by **wfzyx** (citation author "Panisa, Victor Hugo"; Ollaya README names him). Note the shipped `marker_calibration.json` must travel with the weights ("Do not drop it") — a pinning requirement, not a licence term. Calibration is in-sample on JevBench public ("out of domain Von can be confidently wrong") — same family of caveat as B4.
- **Verdict:** (a) clear · (b) clear (recalibrate before auto-admit) · (c) clear with pin incl. calibration file.

## 3. Stack candidates

### 3a. Docling (IBM-originated; `docling-project/docling`)
- **Licence:** MIT (GitHub API `license.spdx_id = "MIT"`; org `docling-project`, successor of IBM's DS4SD repo; 68k stars). Checked 2026-10-02.
- **Commercial use / redistribution / attribution:** Yes / yes / MIT notice + permission notice retention.
- **Fine-tune/derivative terms:** n/a (toolkit). **Training-data disclosure:** n/a.
- **Weight provenance:** Toolkit publishes no weights — **but Docling downloads document-AI models (layout, TableFormer, …) at runtime, each with its own HF licence. Those are out of this audit's scope and unaudited**: *not found (looked: this audit covered the toolkit repo only; model-by-model audit of Docling's pulled artefacts is a required follow-up before adoption)*.
- **Verdict:** (a) clear for the toolkit · (b)/(c) clear for the toolkit, **pending the runtime-model sub-audit**.

### 3b. `Qwen/Qwen3-Embedding-0.6B`
- **Licence:** Apache-2.0 (HF tag + cardData; base `Qwen/Qwen3-0.6B-Base`; revision sha `97b0c614be4d77ee51c0cef4e5f07c00f9eb65b3`; lastModified 2026-04-20). Checked 2026-10-02.
- **Commercial use / redistribution / attribution / derivative terms:** Yes / permissive / §4 / Apache-2.0.
- **Training-data disclosure:** **not found (looked: HF API record fields, 2026-10-02)** — the embedding-series paper exists for the family (arXiv:2506.05176 is cited on the Reranker sibling; the 0.6B embedder record itself carries no dataset disclosure).
- **Provenance:** Published by **Qwen** (Alibaba). **Verdict:** (a)/(b)/(c) clear with pin.

### 3c. `Qwen/Qwen3-Reranker-0.6B`
- **Licence:** Apache-2.0 (HF tag + cardData; base `Qwen/Qwen3-0.6B-Base`; arXiv:2506.05176; revision sha `e61197ed45024b0ed8a2d74b80b4d909f1255473`; lastModified 2026-04-16). Checked 2026-10-02.
- **Commercial use / redistribution / attribution / derivative terms:** Yes / permissive / §4 / Apache-2.0.
- **Training-data disclosure:** via the arXiv paper cited on the record; dataset composition not verified here (paper not reviewed).
- **Provenance:** Published by **Qwen**. **Verdict:** (a)/(b)/(c) clear with pin.

### 3d. `tasksource/ModernBERT-large-nli`
- **Licence:** Apache-2.0 (HF tag + cardData; base `answerdotai/ModernBERT-large` Apache-2.0; revision sha `ca476cb923a8637073d4ceb0f19f7fc236e260d4`; lastModified 2025-01-04). Checked 2026-10-02.
- **Commercial use / redistribution / attribution / derivative terms:** Yes / permissive / §4 / Apache-2.0.
- **Training-data disclosure:** cardData names training datasets (`nyu-mll/glue`, `facebook/anli`); tasksource's full NLI mixture beyond those fields: **not found (looked: HF API record cardData, 2026-10-02)**.
- **Provenance:** Published by **tasksource**. **Verdict:** (a)/(b)/(c) clear with pin.

## 4. In-zone additions of 2026-09-29

### 4a. `incoai/Qwen3.8-27B-Splash` (Splash server + weights) and the Qwen3.8-27B base
- **Licence (Splash repo):** Apache-2.0 — cardData `license: "apache-2.0"` **and** the repo's LICENSE file fetched directly: full Apache-2.0 text with appendix copyright **"Copyright 2026 Alibaba Cloud"** (i.e., the carried notice is Alibaba/Qwen's, consistent with a derivative-distribution chain — see D5). Revision sha `9d27070b71f7142c6b6025f03ac011d70a73cb48`; lastModified 2026-09-18; 17.4 GB target+draft+vision layout, 4-bit.
- **Base-model licence (the ticket's audit ask):** `Qwen/Qwen3.8-27B` — `license:apache-2.0` (HF API, created 2026-08-05 by Qwen). Chain: `Qwen/Qwen3.8-27B` (Apache-2.0) → `incoai/Qwen3.8-27B-DFlash2` (Apache-2.0 tag + cardData; speculative-decoding draft model; revision sha `015e795645c74b1a0eeef3b570031fb62e769bc5`; lastModified 2026-09-17) → `incoai/Qwen3.8-27B-Splash` (Apache-2.0). Every link checked 2026-10-02; chain clean.
- **Commercial use / redistribution / attribution / derivative terms:** Yes / permissive / §4 incl. the Alibaba Cloud notice / Apache-2.0 throughout.
- **Training-data disclosure:** for Qwen3.8-27B, **not found (looked: HF search records for Qwen3.8-27B, 2026-10-02 — no dataset disclosure captured in this audit; Qwen family practice suggests a card section, verify at adoption)**.
- **Splash server (runtime):** `github.com/incoai/splash` — Apache-2.0 (GitHub API), "A local inference engine for Apple silicon, built around the model", created 2026-09-18. **Platform caveat B5** (Metal/Apple-silicon focus).
- **Verdict:** (a) clear · (b) clear · (c) clear with pin + D5 confirmation + platform check.

### 4b. `lainsoykaf/Qwen3-VL-Embedding-8B-GGUF` (Q4_K_M) + base
- **Quantizer's terms:** Apache-2.0 (cardData `license: "apache-2.0"`); README adds **no** terms of its own — it is conversion-only ("This repository only contains converted GGUF artifacts for local inference workflows") and points users back upstream: "please review and follow the original model card, license, and any upstream usage guidance." Revision sha `ba69062596a0a71b0dd06659c012ccc2ec4598c5`; lastModified 2026-04-13; files `Qwen3-VL-Embedding-8B-Q4_K_M.gguf` + `mmproj-Qwen3-VL-Embedding-8B-f16.gguf`. Checked 2026-10-02.
- **Base licence:** `Qwen/Qwen3-VL-Embedding-8B` — `license:apache-2.0` (HF API; base `Qwen/Qwen3-VL-8B-Instruct`, itself `license:apache-2.0`, verified; sentence-transformers; arXiv:2601.04720; revision sha `2c4565515e0f265c6511776e7193b22c0968ddc7`). Chain clean to Apache-2.0 at every link.
- **Commercial use / redistribution / attribution / derivative terms:** Yes (weights are a redistribution of converted base weights — Apache-2.0 permits, §4 conditions apply) / yes / §4 / Apache-2.0.
- **Training-data disclosure:** **not found (looked: HF API records for the GGUF repo and the Qwen3-VL-Embedding-8B base, 2026-10-02)**.
- **Serving runtime:** llama.cpp — MIT (GitHub API `license.spdx_id = "MIT"`, repo `ggml-org/llama.cpp`), as the ticket stated — **verified**.
- **Verdict:** (a) clear · (b) clear · (c) clear with pin (record both revision shas and, at adoption, the per-file LFS sha256 via the HF API).

## 5. Verdict table — per use

**(a) developer/CI use** (local, pinned, synthetic data only — the ADR 0042 contract test) · **(b) public clinic-demo** (models pulled at runtime, never vendored; public visitors' text may reach the models) · **(c) VendorPM production** (customer-confidential data in the zone; ADR 0041 auto-admit bands).

| Item | (a) dev/CI | (b) clinic-demo | (c) VendorPM prod |
|---|---|---|---|
| Ollaya runtime | ✅ | ✅ | ✅ pin binary |
| llama.cpp | ✅ | ✅ | ✅ |
| Splash server (incoai) | ✅ | ✅ (macOS host) | ✅ if zone host suits (B5) |
| `laya:en` | ✅ | ✅ | ✅ pin + recalibrate |
| `laya:typed-decisions` | ✅ | ✅ (B4) | ✅ (B4) pin |
| `decider` 0.8b/2b/4b | ✅ | ✅ | ✅ pin; D4 outstanding |
| **`winnow:e4b`** | ✅ (pin sha256 `840e3f50…`) | ⚠️ **unclear (B1)** | ⛔ **blocked pending D1/D2** |
| NLI deberta-v3-large | ✅ | ✅ | ✅ |
| NLI modernbert-large | ✅ | ✅ | ✅ after B2 tag fix |
| GLiClass | ✅ | ✅ | ✅ pin |
| Qwen3Guard | ✅ | ✅ | ✅ pin |
| `kev:0.8b` | ✅ | ✅ | ✅ pin |
| `von` | ✅ | ✅ | ✅ pin incl. `marker_calibration.json` |
| Docling (toolkit) | ✅ | ✅* | ✅* (*pending its runtime-model sub-audit) |
| Qwen3-Embedding-0.6B | ✅ | ✅ | ✅ pin |
| Qwen3-Reranker-0.6B | ✅ | ✅ | ✅ pin |
| tasksource/ModernBERT-large-nli | ✅ | ✅ | ✅ pin |
| `incoai/Qwen3.8-27B-Splash` | ✅ | ✅ (macOS host) | ✅ pin + D5 |
| `lainsoykaf/…-GGUF` Q4_K_M | ✅ | ✅ | ✅ pin |

**Cross-cutting conditions for every ✅ above:** pin the exact revision/digest (Ollaya's commit+sha256 pinning covers registry pulls; HF revisions recorded above or obtainable via the HF API); keep Apache §4 NOTICE/LICENCE propagation for anything we redistribute (the demo redistributes nothing; VendorPM redistributes nothing — serving is use); record licence + publisher + digest on every judgment-ledger row per ADR 0040/0042 ("a pinned digest"); treat publisher-reported accuracy (ADR 0041) and shipped calibrations (B4) as unverified inputs to calibration, never as facts.

## 6. Summary of the biggest risks

**The single biggest risk is the Gemma chain under `winnow:e4b`, which is exactly the model Ollaya recommends as its default.** The licence record itself is permissive and well-documented — EldanRing publishes Apache-2.0, LICENSE, NOTICE, and a SHA256SUMS file we can pin (`840e3f50…` for the Q8_0 GGUF the ADR already sizes) — but the model is a derivative of Google's Gemma 4, and Google simultaneously publishes a Prohibited Use Policy whose §3.4 prohibits using Gemma "or Model Derivatives" for *"automated decisions in domains that affect material or individual rights or well-being (e.g., finance, legal, employment, healthcare, housing, insurance, and social welfare)"*. A clinic triage demo is in the plain text of that clause, and whether the policy binds at all under Gemma 4's Apache-2.0 regime is not answerable from the public record — the Gemma 4 licence page contains only the Apache text while the policy persists as a separate document. Until EldanRing and Google answer (D1/D2), `winnow:e4b` must not be the demo or production default, and the selection should fall back to the clean chains (`laya`, `decider` on Apache-2.0 Qwen3.5, `von`, `kev`); the compounding risk is that its training data is explicitly not released, so even a favourable licence answer leaves a provenance gap.

**The second risk is that registry metadata is demonstrably fallible, and our own doctrine already assumed it.** We caught a concrete error — `ollaya-dev/nli` tagged `license:mit` over an Apache-2.0 upstream — and our own ADR 0042 claims the registry mixes in "proprietary" licences that this audit could not find anywhere in the audited set; both show that a registry tag must never be treated as a licence. Add the structural exposures: Ollaya is a days-old, single-maintainer project (Mert Cobanov) whose whole value is a wire compatibility with a twelve-day-old protocol vendor; the key weights publishers are individuals (EldanRing, Mapika, wfzyx) whose re-licensing or deletion risk is real, which makes pinned digests and mirrors-of-record a precondition, not a nicety; training-data disclosure ranges from excellent (`von`, `kev`) to partial (`decider`'s teacher-generated mixture, D4) to explicitly withheld (`winnow`); and shipped calibrations are in-sample (`laya:typed-decisions`, `von`), which under ADR 0041 means no auto-admit band may be earned from publisher-fitted temperatures. None of this blocks uses (a) or a `laya`/`decider`-based (b)/(c) — every chain in scope terminates in Apache-2.0 or MIT — but it does mean the licence audit ADR 0042 made a contract prerequisite should be re-run per pinned revision, not done once.
