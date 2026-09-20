<img src="https://r2cdn.perplexity.ai/pplx-full-logo-primary-dark%402x.png" style="height:64px;margin-right:32px"/>

# I know that ash use of spark limits dialyzer effectiveness and other issues in elixir tooling. What's the root cause to these issues? Has a solution been proposed? Is it viable for us to put investments into the tooling and smooth over the ash issues and give it the same level or even better of language server and strict typing support and and other fancy things? Give me a road map of problems to fix and the current ongoing efforts and state-of-the-art for each one as well as how other languages have sold these issues and whether that's been explored in this space yet

Yes—this is investable, and Ash could achieve a substantially better domain-aware development experience than ordinary Elixir. The viable goal is not “make arbitrary Elixir as statically sound as Rust or Gleam,” but **make Ash/Spark a typed declarative island with precise generated boundaries, first-class IDE semantics, and native compiler integration**.

## Root cause

Ash places multiple semantic layers in one source file:

- Elixir sees macro calls such as `attribute`, `action`, and `relationship`.
- Spark interprets those calls as a declarative model, applies extensions and transformations, and validates it.
- Ash uses the resulting model to generate structs, code interfaces, runtime metadata, validation paths, and other behavior.

Most tooling sees either the original macro-shaped AST or the compiled generated code—not the complete semantic relationship between them. Spark already possesses much of the required information, including DSL schemas, entities, options, source annotations, transformations, introspection, and autocomplete support, but that information is not exposed through one stable, serializable tooling interface.

Dialyzer compounds the problem because success typing only reports contradictions it can prove. Broad generated boundaries such as `map()`, `term()`, and `keyword()` discard information Ash actually knows; meanwhile, accepted pre-casting input is not necessarily the same type as normalized action input.

## Recommended architecture

The cornerstone should be a versioned **Spark/Ash semantic manifest** containing:

- Resource attributes, relationships, actions, arguments, calculations, policies, and code interfaces.
- Required and optional input keys, constraints, return types, errors, pagination, and bang/non-bang behavior.
- Stable symbol IDs for fields, actions, calculations, and generated functions.
- Complete source maps from generated declarations and transformed entities back to DSL declarations.
- Extension provenance and deterministic cache hashes.
- Separate **accepted-input** and **normalized-value** types.

This would be Ash's equivalent of TypeScript declaration files: a compact semantic surface that tools can consume without re-running arbitrary framework code.[^1_1][^1_2] Language-server adapters, Dialyzer typespec generation, future Elixir signatures, documentation, agents, and refactoring tools could all consume the same artifact.

## Investment roadmap

| Phase | Deliverable | Priority |
| :-- | :-- | :-- |
| 0 | Representative corpus, latency/accuracy benchmarks, semantic-manifest RFC | P0 |
| 1 | Expert completion parity with the existing Spark ElixirSense integration | P0 |
| 2 | Serializable semantic manifest, symbol IDs, source maps, expansion preview | P0 |
| 3 | Precise code-interface contracts and accepted-versus-normalized type algebra | P0 |
| 4 | Build-free diagnostics, navigation, references, rename, and code actions | P1 |
| 5 | Backend for Elixir's native set-theoretic signatures when its API stabilizes | P1 |
| 6 | Experimental typed loads, relationship paths, filters, and expressions | P2 |

Expert currently has open requests specifically for Ash support and parity with Spark's existing integration. Porting that plugin is a useful near-term project, but it should be treated as a bridge—the durable implementation should consume semantic manifests rather than reproduce Ash knowledge inside each language server.

## What is achievable

A well-funded effort can realistically provide:

- Precise action completion and signature help.
- Missing/unknown input diagnostics before compilation.
- Typed attribute, relationship, filter, sort, and load paths.
- Hover showing effective types, constraints, and extension provenance.
- Go-to-definition and rename across DSL-generated symbols.
- Better generated `@spec` declarations for current tooling.
- Native set-theoretic signatures once Elixir exposes a supported mechanism.
- Refactors that extract inline callbacks and reduce recompilation.
- Machine-readable semantic queries for coding agents and MCP tooling.

Ash has already explored localized improvements—for example, generated typed-struct constructor heads that allow Dialyzer to catch missing fields—but these are point solutions rather than a unified architecture. There are also still semantic differences in generated interfaces, including an open issue where code-interface `get_by` does not apply equivalent argument type checking.

## Important boundary

Elixir 1.20's native checker now performs whole-function inference, but user-defined set-theoretic function signatures and fully typed structs remain later-stage parts of the language roadmap; the Elixir team also considers existing Erlang typespecs insufficient for the ultimate system.[^1_3][^1_4] Therefore:

- Do not fork or build a competing full Elixir checker.
- Do not depend directly on private `Module.Types` internals.
- Build an Ash-owned type algebra and semantic IR.
- Emit legacy typespecs today and native signatures through a backend later.
- Collaborate upstream using Ash applications as demanding compiler test cases.

Rust's macro expansion, source mapping, and isolated proc-macro server are the best architectural precedent.[^1_5] TypeScript's generated declarations provide the best packaging precedent, while Kotlin KSP/FIR demonstrates how a stable symbol model can support generated declarations without forcing every IDE to understand every framework.[^1_6][^1_7]

## Recommendation

Fund a small senior team—an Elixir compiler/LSP engineer, an Ash/Spark core engineer, and fractional type-systems expertise—for an initial 9–12 months. Gate later investment on completion latency, diagnostic precision, navigation accuracy, and measured reductions in type-related defects.

The full report includes the detailed problem taxonomy, current efforts, comparative language analysis, phase exit criteria, team model, and risks.

<span style="display:none">[^1_10][^1_100][^1_101][^1_102][^1_103][^1_104][^1_105][^1_106][^1_107][^1_108][^1_109][^1_11][^1_110][^1_111][^1_112][^1_113][^1_114][^1_115][^1_116][^1_117][^1_118][^1_119][^1_12][^1_120][^1_121][^1_122][^1_123][^1_124][^1_125][^1_126][^1_127][^1_128][^1_129][^1_13][^1_130][^1_131][^1_132][^1_133][^1_134][^1_135][^1_136][^1_137][^1_138][^1_139][^1_14][^1_140][^1_141][^1_142][^1_143][^1_144][^1_145][^1_146][^1_147][^1_148][^1_149][^1_15][^1_150][^1_151][^1_152][^1_153][^1_154][^1_155][^1_156][^1_157][^1_158][^1_159][^1_16][^1_160][^1_161][^1_162][^1_163][^1_164][^1_165][^1_166][^1_167][^1_168][^1_169][^1_17][^1_170][^1_171][^1_172][^1_173][^1_174][^1_175][^1_176][^1_177][^1_178][^1_179][^1_18][^1_180][^1_181][^1_182][^1_183][^1_19][^1_20][^1_21][^1_22][^1_23][^1_24][^1_25][^1_26][^1_27][^1_28][^1_29][^1_30][^1_31][^1_32][^1_33][^1_34][^1_35][^1_36][^1_37][^1_38][^1_39][^1_40][^1_41][^1_42][^1_43][^1_44][^1_45][^1_46][^1_47][^1_48][^1_49][^1_50][^1_51][^1_52][^1_53][^1_54][^1_55][^1_56][^1_57][^1_58][^1_59][^1_60][^1_61][^1_62][^1_63][^1_64][^1_65][^1_66][^1_67][^1_68][^1_69][^1_70][^1_71][^1_72][^1_73][^1_74][^1_75][^1_76][^1_77][^1_78][^1_79][^1_8][^1_80][^1_81][^1_82][^1_83][^1_84][^1_85][^1_86][^1_87][^1_88][^1_89][^1_9][^1_90][^1_91][^1_92][^1_93][^1_94][^1_95][^1_96][^1_97][^1_98][^1_99]</span>

<div align="center">⁂</div>

[^1_1]: https://deepwiki.com/rust-lang/rust-analyzer/5.2-macro-expansion

[^1_2]: https://blog.jetbrains.com/rust/2022/12/05/what-every-rust-developer-should-know-about-macro-support-in-ides/

[^1_3]: https://github.com/elixir-lang/elixir/issues/12645

[^1_4]: https://github.com/elixir-lsp/elixir-ls

[^1_5]: https://github.com/lukaszsamson/elixir-ls-1

[^1_6]: https://elixirforum.com/t/recent-spark-performance-improvements-should-have-significant-positive-effects-on-ash-application-performance/59076/

[^1_7]: https://elixirforum.com/t/reducing-incremental-compilation-times-in-phoenix-ash-project/72113/

[^1_8]: https://hexdocs.pm/elixir/1.17.1/gradual-set-theoretic-types.html

[^1_9]: https://hexdocs.pm/elixir/1.18.0/gradual-set-theoretic-types.html

[^1_10]: https://github.com/elixir-lang/elixir/blob/main/CHANGELOG.md

[^1_11]: https://hexdocs.pm/ash/Ash.CodeInterface.html

[^1_12]: https://hexdocs.pm/ash/2.11.4/code-interface.html

[^1_13]: https://elixir-lang.org/blog/2026/02/26/eager-literal-intersections/

[^1_14]: https://elixir-lang.org/blog/2026/03/19/lazy-bdds-with-eager-literal-differences/

[^1_15]: https://www.typescriptlang.org/docs/handbook/2/type-declarations.html

[^1_16]: https://www.typescriptlang.org/docs/handbook/release-notes/typescript-5-5.html

[^1_17]: https://kotlinlang.org/docs/ksp-overview.html

[^1_18]: https://fasterthanli.me/articles/proc-macro-support-in-rust-analyzer-for-nightly-rustc-versions

[^1_19]: https://ferrous-systems.com/blog/testing-proc-macros/

[^1_20]: https://botmonster.com/coding/gleam-erlang-developers-type-safe-beam-vm/

[^1_21]: https://langindex.dev/languages/gleam/

[^1_22]: https://arxiv.org/pdf/2108.08027.pdf

[^1_23]: https://github.com/JetBrains/kotlin/blob/master/docs/fir/fir-plugins.md

[^1_24]: https://gradualizer.hexdocs.pm/gradualizer.html

[^1_25]: https://github.com/josefs/Gradualizer

[^1_26]: https://dl.acm.org/doi/pdf/10.1145/3677995.3678189

[^1_27]: https://academic.oup.com/bioinformatics/article-pdf/36/8/2636/33116488/btz959.pdf

[^1_28]: http://arxiv.org/pdf/1805.11800.pdf

[^1_29]: https://arxiv.org/pdf/2306.06391.pdf

[^1_30]: http://arxiv.org/pdf/2408.14345.pdf

[^1_31]: https://labhub.hopto.org/blog/2026-07-16-elixir-1-20-gradual-typing-milestone?lang=en

[^1_32]: https://byteiota.com/elixirconf-2026-elixir-type-system/

[^1_33]: https://elixir-lang.org/blog/2026/01/09/type-inference-of-all-and-next-15/

[^1_34]: https://kaikai365.com/posts/2026-06-05-elixir-v1-20-gradually-typed-language/

[^1_35]: https://elixir-lang.org/blog/

[^1_36]: https://elixir-lang.org/blog/2026/06/03/elixir-v1-20-0-released/

[^1_37]: https://dev.to/geekmasahiro/elixir-120-has-a-type-system-now-comparing-it-with-rust-and-typescript-31p4

[^1_38]: https://hexdocs.pm/elixir/gradual-set-theoretic-types.html

[^1_39]: https://elixirforum.com/t/elixir-v1-17-0-rc-0-released/63764

[^1_40]: https://gldubc.github.io/

[^1_41]: https://smartlogic.io/podcast/elixir-wizards/s14-e07-set-theoretic-types-elixir-jose-valim/

[^1_42]: https://arxiv.org/pdf/2408.14345.pdf

[^1_43]: https://hexdocs.pm/elixir/1.19.0-rc.0/gradual-set-theoretic-types.html

[^1_44]: https://www.elixirforum.net/tags/performance

[^1_45]: https://elixir-lang.org/blog/2025/12/02/lazier-bdds-for-set-theoretic-types/

[^1_46]: https://arxiv.org/pdf/2503.03826.pdf

[^1_47]: https://arxiv.org/pdf/2412.13581.pdf

[^1_48]: https://arxiv.org/pdf/1703.08219.pdf

[^1_49]: https://github.com/ash-project/ash/blob/main/documentation/topics/development/development-utilities.md

[^1_50]: https://hexdocs.pm/spark/2.5.0/llms.txt

[^1_51]: https://hexdocs.pm/spark/Spark.Dsl.html

[^1_52]: https://hexdocs.pm/spark/get-started-with-spark.html

[^1_53]: https://github.com/ash-project/spark/blob/main/CHANGELOG.md

[^1_54]: https://hexdocs.pm/spark/1.1.55/get-started-with-spark.html

[^1_55]: https://hexdocs.pm/spark/0.2.4/get-started-with-spark.html

[^1_56]: https://hex.pm/packages/spark/2.2.61/files/documentation/tutorials/get-started-with-spark.md

[^1_57]: https://hexdocs.pm/spark/1.1.26/get-started-with-spark.html

[^1_58]: https://hex.pm/packages/spark/2.3.4/files/documentation/tutorials/get-started-with-spark.md

[^1_59]: https://elixirforum.com/t/expert-lsp-compatibility/74451

[^1_60]: https://hexdocs.pm/ash/2.4.11/development-utilities.html

[^1_61]: https://hexdocs.pm/spark/0.3.1/index.html

[^1_62]: https://hexdocs.pm/spark/Spark.CheatSheet.html

[^1_63]: https://hexdocs.pm/spark/2.5.0/spark.epub

[^1_64]: http://arxiv.org/pdf/2305.02991.pdf

[^1_65]: https://arxiv.org/pdf/2203.08877.pdf

[^1_66]: https://arxiv.org/abs/2112.10915

[^1_67]: http://learningelixir.joekain.com/elixir-type-specs/

[^1_68]: https://elixirforum.com/t/dialyzer-woes-how-to-ignore-certain-warnings-in-macro-generated-code/45447

[^1_69]: https://www.bounga.org/elixir/2025/03/31/typing-in-elixir/

[^1_70]: https://elixirexamples.com/05-advanced-topics/02-typespecs/

[^1_71]: https://blog.appsignal.com/2025/04/01/advanced-dialyzer-usage-in-elixir-types-and-troubleshooting.html

[^1_72]: https://mikezornek.com/posts/2021/1/typespecs-and-dialyzer/

[^1_73]: https://www.erlang.org/doc/apps/dialyzer/notes.html

[^1_74]: https://www.reddit.com/r/elixir/comments/1ebk5nm/struggling_to_understand_typespecs_the/

[^1_75]: https://www.alanvardy.com/post/dialyzer-stop-worrying

[^1_76]: https://github.com/Qqwy/elixir-type_check/blob/main/README.md

[^1_77]: https://elixir.hexdocs.pm/1.18.1/Kernel.SpecialForms.html

[^1_78]: https://github.com/elixir-lang/elixir/issues/2478

[^1_79]: https://elixirforum.com/t/how-to-make-dialyzer-more-strict/13854?page=2

[^1_80]: https://brittonbroderick.com/2025/03/30/resolving-dialyzer-issues-in-elixir/

[^1_81]: https://elixirforum.com/t/typespec-and-opts/35495

[^1_82]: https://arxiv.org/abs/2208.04631v1

[^1_83]: https://marketplace.visualstudio.com/items?itemName=ExpertLSP.expert

[^1_84]: https://elixir-lang.org/blog/2024/08/15/welcome-elixir-language-server-team/

[^1_85]: https://zed.dev/docs/languages/elixir

[^1_86]: https://github.com/elixir-tools/next-ls

[^1_87]: https://podcast.thinkingelixir.com/294

[^1_88]: https://expert-lsp.org/the-first-release-candidate/

[^1_89]: https://www.claudepluginhub.com/lsp-servers/expert

[^1_90]: https://expert-lsp.org/

[^1_91]: https://emacs-lsp.github.io/lsp-mode/page/lsp-elixir/

[^1_92]: https://www.linkedin.com/posts/mark-ericksen-66397417_thinking-elixir-podcast-294-compile-times-activity-7434586119788277760-\_pfj

[^1_93]: https://deepwiki.com/elixir-lang/expert

[^1_94]: https://elixir-lsp.github.io/elixir-ls/getting-started/emacs/

[^1_95]: https://elixirforum.com/tags/lsp

[^1_96]: https://www.elixir-tools.dev/news/the-elixir-tools-update-vol-3/

[^1_97]: https://github.com/expert-lsp/expert

[^1_98]: https://arxiv.org/pdf/2109.01002.pdf

[^1_99]: https://arxiv.org/pdf/2301.11117.pdf

[^1_100]: http://arxiv.org/pdf/2203.16697.pdf

[^1_101]: https://arxiv.org/pdf/2408.14031.pdf

[^1_102]: https://arxiv.org/pdf/2112.10328.pdf

[^1_103]: http://arxiv.org/pdf/2502.15246.pdf

[^1_104]: https://hexdocs.pm/ash/Ash.html

[^1_105]: https://hexdocs.pm/ash/2.5.9/code-interface.html

[^1_106]: https://hexdocs.pm/ash/2.4.1/code-interface.html

[^1_107]: https://hexdocs.pm/ash/2.4.3/Ash.html

[^1_108]: https://hexdocs.pm/ash/3.2.2/code-interfaces.html

[^1_109]: https://hexdocs.pm/ash/3.0.5/code-interfaces.html

[^1_110]: https://hexdocs.pm/ash/3.4.60/code-interfaces.html

[^1_111]: https://hexdocs.pm/ash/3.1.0/code-interfaces.html

[^1_112]: https://hexdocs.pm/ash/Ash.Query.html

[^1_113]: https://hexdocs.pm/ash/3.0.0-rc.39/code-interfaces.html

[^1_114]: https://hexdocs.pm/ash/2.14.11/code-interface.html

[^1_115]: https://hexdocs.pm/ash/1.6.2/Ash.html

[^1_116]: https://hexdocs.pm/ash/2.5.5/code-interface.html

[^1_117]: https://arxiv.org/pdf/2311.04527.pdf

[^1_118]: http://arxiv.org/pdf/2412.08842.pdf

[^1_119]: https://drops.dagstuhl.de/opus/volltexte/2015/5218/pdf/8.pdf

[^1_120]: https://arxiv.org/pdf/2302.12163.pdf

[^1_121]: https://arxiv.org/pdf/2307.05557.pdf

[^1_122]: https://arxiv.org/pdf/2408.11954.pdf

[^1_123]: https://deepwiki.com/rickclephas/KMP-NativeCoroutines/2.4-compiler-plugin-internals

[^1_124]: https://rust-lang.github.io/rust-analyzer/src/ide/expand_macro.rs.html

[^1_125]: https://rust-lang.github.io/rust-analyzer/src/proc_macro_api/lib.rs.html

[^1_126]: https://deepwiki.com/rickclephas/KMP-NativeCoroutines/2.5-ksp-processor

[^1_127]: https://lib.rs/development-tools/procedural-macro-helpers

[^1_128]: https://slack-chats.kotlinlang.org/t/30387430/i-m-a-complete-codegen-noob-but-can-someone-explain-to-me-if

[^1_129]: https://git.joshthomas.dev/language-servers/rust-analyzer/src/commit/728990a5807882276e34f1f581f70a59f61ba991/docs/dev/guide.md

[^1_130]: https://arxiv.org/pdf/1811.08834.pdf

[^1_131]: https://arxiv.org/html/2406.01409v1

[^1_132]: https://resmilitaris.net/index.php/resmilitaris/article/download/4432/3439

[^1_133]: https://hexdocs.pm/ash_profiler/readme.html

[^1_134]: https://elixirforum.com/t/elixir-1-19-compilation-performance-have-you-noticed-a-difference/73030/

[^1_135]: https://deepwiki.com/diffo-dev/ash_neo4j/3.2-dsl-validation-system

[^1_136]: https://deepwiki.com/diffo-dev/ash_neo4j/3.3-dsl-validation-system

[^1_137]: https://hex.pm/packages/ash_profiler

[^1_138]: https://elixirforum.com/t/improve-regex-performance-or-temporarely-disable-during-bulk-insertion/73890

[^1_139]: https://deepwiki.com/ash-project/ash/12.1-extension-system

[^1_140]: https://deepwiki.com/albinkc/ash/2-resource-system

[^1_141]: https://www.answeroverflow.com/m/1390721121300643850

[^1_142]: https://elixirforum.com/t/elixir-1-19-compilation-performance-have-you-noticed-a-difference/73030?page=2

[^1_143]: https://www.answeroverflow.com/m/1406804037814194229

[^1_144]: https://elixirforum.com/t/defimpl-for-some-other-module-stopped-working-after-upgrade-to-1-19/72955

[^1_145]: https://arxiv.org/abs/2104.08366v1

[^1_146]: https://dl.acm.org/doi/pdf/10.1145/3622860

[^1_147]: https://pmc.ncbi.nlm.nih.gov/articles/PMC5070591/

[^1_148]: https://hexdocs.pm/elixir/1.17.0/gradual-set-theoretic-types.html

[^1_149]: https://hexdocs.pm/elixir/1.17.3/changelog.html

[^1_150]: https://hexdocs.pm/elixir/1.17.2/changelog.html

[^1_151]: https://hexdocs.pm/elixir/1.17.0-rc.0/changelog.html

[^1_152]: https://updateshub.net/en/source/elixir-blog

[^1_153]: https://elixir-lang.org/blog/2023/09/20/strong-arrows-gradual-typing/

[^1_154]: https://hexdocs.pm/elixir/1.20.0-rc.0/types-cheat.html

[^1_155]: http://arxiv.org/pdf/2409.13896.pdf

[^1_156]: https://arxiv.org/pdf/2210.13945.pdf

[^1_157]: https://github.com/elixir-lang/elixir/issues/13974

[^1_158]: https://github.com/elixir-lang/elixir/issues/15154

[^1_159]: https://github.com/elixir-lang/elixir/issues

[^1_160]: https://github.com/elixir-lang/elixir/releases

[^1_161]: https://github.com/elixir-lang/elixir/issues/2456

[^1_162]: https://github.com/elixir-lang/elixir/issues/4915

[^1_163]: https://github.com/elixir-lang/elixir/issues/14547

[^1_164]: https://github.com/elixir-lang/elixir/issues/10973

[^1_165]: https://github.com/elixir-lang/elixir/issues/9758

[^1_166]: https://arxiv.org/pdf/2210.12246.pdf

[^1_167]: https://arxiv.org/pdf/2102.09713.pdf

[^1_168]: https://github.com/elixir-lsp/elixir-ls/blob/master/README.md

[^1_169]: https://deepwiki.com/lexical-lsp/lexical/5.2-ast-analysis

[^1_170]: https://open-vsx.org/extension/ExpertLSP/expert

[^1_171]: https://github.com/elixir-lsp/elixir-ls/blob/master/apps/language_server/lib/language_server/dialyzer.ex

[^1_172]: https://deepwiki.com/elixir-lsp/elixir-ls/2.1-server-and-request-handling

[^1_173]: https://forum.elixirforum.com/t/elixirls-the-elixir-language-server/5857/213

[^1_174]: https://hex.pm/packages/gradualizer/0.2.0/files/src/user_default.erl

[^1_175]: https://github.com/nshkrdotcom/ex_dbg/blob/main/RESEARCH_CPG_ELIXIR.md

[^1_176]: https://www.matterai.so/guides/gleam-on-beam-building-type-safe-fault-tolerant-systems-with-functional-erlang

[^1_177]: https://lambdadays.org/static/upload/media/16593843608040212radekszymczyszynwhatasnewingradualizer_graduallytypingerlangandelixir_lambdadays20221.pdf

[^1_178]: https://hex.pm/packages/gradualizer

[^1_179]: https://www.skillveris.com/glossary/gleam-language

[^1_180]: https://devscampus.com/latest/gleam-1-4-type-safe-beam-concurrency

[^1_181]: https://fitech101.aalto.fi/en/courses/modern-and-emerging-programming-languages/part-3/1-overview

[^1_182]: https://gist.github.com/erszcz/4d43a77464c87a514e71eecf2811af63

[^1_183]: https://hex.pm/packages/gradualizer/0.2.0/files/LICENSE


---

# Expand scope to include tidewave (or tidewave like) runtime agentic support, the ash extension "usage" convention of generating docs for AI agents, and the scope of ash_enterprise (processes, dmn, feel, rules and compliance, etc). Consider the efforts of Clarity project as well. Any tie ins? Update the report and give me a new one ready to hand off to teams for planning.

Yes—the expanded scope strengthens the investment case. Ash already has the beginnings of a uniquely integrated **semantic-development and agentic-runtime platform**: Spark supplies declarative metadata, Clarity supplies an extensible semantic graph, UsageRules supplies package-authored agent guidance, Tidewave supplies runtime grounding, and Ash Enterprise supplies governed business semantics.

# Ash Intelligence Platform Plan

**Planning report — September 2026**

## Executive decision

The recommended objective is broader than improving Dialyzer or porting Ash completions to Expert. The investment should create an **Ash semantic intelligence platform** serving:

- Human developers through Expert and editor integrations.
- Static analyzers through generated contracts and type information.
- Coding agents through UsageRules and structured semantic queries.
- Runtime agents through Tidewave-compatible MCP capabilities.
- Architects through Clarity’s graph and visualization model.
- Enterprise operators through governed process, decision, policy, compliance, and evidence tools.

The opportunity is unusually strong because these tools need substantially the same information. Resource attributes, relationships, actions, policies, process definitions, decision tables, source locations, types, provenance, and documentation should not be independently rediscovered by every consumer.

The core investment should therefore be a **versioned semantic protocol**, not five unrelated integrations.

## Current landscape

| Component | Current strength | Important limitation | Recommended role |
| :-- | :-- | :-- | :-- |
| Spark/Ash | Rich declarative metadata, schemas, extension composition, transformation and introspection | No stable cross-tool semantic artifact or protocol | Canonical semantic compiler |
| Spark ElixirSense | Existing DSL completion for sections, entities, arguments, option schemas, behaviors and Spark types | Coupled directly to ElixirSense internals and tolerant parsing heuristics | Reference implementation and compatibility bridge |
| Expert | Official Elixir language server with explicit open requests for Ash support | Ash support and prior Spark completion parity remain open | Primary editor consumer |
| UsageRules | Dependency-authored guidance, AGENTS files, skills and documentation search | Primarily prose; lacks semantic validation and project-specific runtime context | Agent knowledge plane |
| Tidewave | Runtime evaluation, logs, SQL, exact-version documentation and source navigation | Generic application tools; no public plug-in API for package-contributed tools | Runtime grounding and interaction plane |
| Clarity | Extensible introspection, semantic graph, provenance, filtering and visualization | Primarily an in-process Erlang-term graph; not yet a portable semantic protocol | Graph projection, analysis and human exploration |
| Ash Enterprise | Processes, approvals, DMN, FEEL, triggers, policies, audit and compliance foundations | Authoring, static analysis, explanations, migration and evidence gaps | Governed business-semantics plane |

Expert has two open Ash issues: one requests parity with Spark’s existing ElixirSense support, and another identifies Ash completion as critical functionality lost in the migration from ElixirLS. Spark’s current plugin already understands DSL sections, entities, extension patches, schemas, argument positions, Spark types and behavior implementations; it is therefore a valuable executable specification, but its direct dependency on ElixirSense APIs makes it the wrong long-term abstraction boundary.

## Unified architecture

The platform should be organized into five cooperating layers.

```text
                 Expert / Editors / CI / Agents
                           |
               Semantic Query Protocol
                           |
        +------------------+------------------+
        |                  |                  |
  Static Manifest    Live Runtime View   Explanation/Evidence
        |                  |                  |
     Spark/Ash       Tidewave adapter      Ash Enterprise
        |                  |                  |
        +----------- Clarity graph ---------+
                           |
               UsageRules and skills
```


### Semantic compiler

Spark should compile each DSL module into a normalized semantic representation containing:

- Domains and resources.
- Attributes, aggregates, calculations and relationships.
- Actions, arguments, accepted input forms and normalized value types.
- Policies, checks, bypasses and actor requirements.
- Code interfaces and generated functions.
- Extension-contributed entities and transformations.
- Source ranges for both declarations and generated artifacts.
- Documentation, examples and usage guidance.
- Stable symbol identifiers and compatibility hashes.
- BPMN, DMN, FEEL and compliance entities when their extensions are installed.

This representation should exist in two forms:

- **Portable manifest:** Versioned JSON or another language-neutral format suitable for editors, CI, remote agents and caching.
- **Live semantic service:** An Elixir API that exposes richer runtime values without forcing every consumer to serialize functions, modules or arbitrary Erlang terms.

The portable form must not contain anonymous functions, process identifiers, executable terms or implicitly created atoms. Those constraints are essential for safe remote consumption and version-independent caching.

### Query protocol

A shared query layer should answer questions such as:

- What actions can be called on this resource?
- Which inputs are required, accepted or derived?
- Where is this generated function declared semantically?
- What extension added this entity?
- Which policy controls this operation?
- What process or decision references this action?
- Which rules can produce this result?
- Which data classified as sensitive flows into this process?
- What changed between two semantic manifests?
- Which documentation or usage rules apply at this source location?

Consumers should query this service rather than independently loading Ash modules and reverse-engineering Spark state.

### Runtime overlay

A running application adds information that a static manifest cannot safely or accurately provide:

- Loaded modules and effective application configuration.
- Active tenants, domains and feature flags.
- Process instances and human tasks.
- Published decision versions and tenant customizations.
- Live policy decisions.
- Database schema and migration status.
- Logs, telemetry and failing execution paths.

The runtime service should overlay these facts onto stable semantic IDs from the manifest. Static and runtime tools can then refer to the same action, rule, relationship or process without fragile module-name matching.

### Knowledge plane

UsageRules should remain the package-authored explanation layer, but the platform should distinguish three forms of agent knowledge:


| Knowledge form | Example | Authority |
| :-- | :-- | :-- |
| Semantic facts | Action inputs, return type, policy requirements | Generated from manifest |
| Operational guidance | Run code generation after changing identities | Package-authored UsageRules |
| Project conventions | Use domain code interfaces rather than direct resource calls | Repository-authored rules |

UsageRules already manages AGENTS-style files, package sub-rules, generated `SKILL.md` files, documentation search, exact package selection and composed Ash ecosystem skills. Ash itself distributes topic-specific rules for actions, authorization, code interfaces, migrations, relationships, filters, testing and other framework concepts.

The right evolution is not to replace those documents with generated text. It is to let UsageRules package **hand-written judgment plus generated semantic references and executable checks**.

### Graph projection

Clarity should consume the semantic protocol and project it into an extensible graph. It should not become the canonical compiler representation.

Clarity already models applications using vertices, labeled edges, queryable fields, indexes, filtered subgraphs, provenance relationships and update counters. Its introspector behavior allows built-in or user-defined modules to add vertices and relationships while deferring work until dependencies are available.

That makes Clarity well suited to:

- Architecture visualization.
- Dependency and impact analysis.
- Documentation coverage.
- Security and compliance perspectives.
- Process-decision-resource lineage.
- Agent graph queries.
- Ontology and data-dictionary generation.
- Human exploration of generated semantics.

Clarity’s current persisted graph uses ETS files and arbitrary Erlang terms and explicitly warns that only trusted graphs should be loaded. A portable Ash semantic manifest should therefore sit beneath Clarity rather than adopting Clarity’s persistence format as the public protocol.

## Tidewave integration

Tidewave provides the correct runtime model: connect an agent to the running development application rather than asking it to infer runtime behavior from files. Its current Phoenix server exposes application evaluation, logs, database queries, exact-version dependency documentation and source locations through MCP.

### Near-term approach

Do not fork Tidewave immediately. Create an `ash_agent_runtime` package that can operate in two modes:

- As a standalone MCP server or proxy.
- Through a future Tidewave package-tool extension API.

The current Tidewave tool list is assembled directly from its internal Logs, Source, Eval and Ecto modules and stored in a private ETS registry. The protocol handler currently advertises tools but no MCP prompts, resources or resource templates, so package-contributed tools are not yet a first-class public extension mechanism.

The first upstream collaboration proposal should introduce:

```elixir
config :tidewave,
  tool_providers: [
    Ash.AgentTools,
    AshEnterprise.AgentTools
  ]
```

A provider might implement:

```elixir
@callback tools(context()) :: [Tidewave.Tool.t()]
@callback resources(context()) :: [Tidewave.Resource.t()]
@callback prompts(context()) :: [Tidewave.Prompt.t()]
```

If Tidewave does not want a package-extension API, a separate MCP server can safely coexist while delegating generic evaluation, source, logging and database operations to Tidewave.

### Ash runtime tools

The initial Ash tool surface should be read-oriented:


| Tool | Purpose |
| :-- | :-- |
| `ash_list_domains` | Discover effective Ash domains |
| `ash_describe_resource` | Return fields, relationships, actions and source locations |
| `ash_describe_action` | Show accepted input, normalized types, return contract and policies |
| `ash_explain_query` | Explain filters, loads, aggregates and resulting data-layer plan |
| `ash_validate_input` | Cast and validate action input without committing |
| `ash_check_authorization` | Evaluate whether an actor can perform an action |
| `ash_explain_forbidden` | Produce a redacted policy explanation |
| `ash_trace_action` | Run an instrumented action in a controlled development context |
| `ash_semantic_search` | Search symbols, descriptions and graph relationships |
| `ash_diff_manifest` | Compare current semantics against another branch or build |

These tools should return structured JSON plus a concise textual rendering. The JSON should carry stable semantic IDs so agents can use results in later calls without repeating natural-language symbol resolution.

### Enterprise runtime tools

Ash Enterprise should add a separate, more restrictive capability set:


| Area | Read tools | Mutating tools |
| :-- | :-- | :-- |
| Processes | Describe definition, inspect instance, explain current state, list enabled transitions | Start test instance, complete sandbox task |
| Decisions | Describe versions, test inputs, explain result, compare definitions | Create draft, publish after approval |
| FEEL | Parse, infer available context, evaluate, trace null propagation | None |
| Policies | Explain effective access and obligations | None |
| Compliance | Query controls, evidence and lineage | Attest or approve with human confirmation |
| Tenant configuration | Compare baseline and fork, calculate drift | Fork, migrate or publish after explicit review |

Mutating tools should not initially be available through general coding-agent sessions. They should require a separate tool provider with explicit configuration, actor identity, tenant identity, confirmation, audit logging and environment restrictions.

## UsageRules evolution

UsageRules should become the **distribution mechanism for agent knowledge contracts**, while the semantic manifest remains the source for machine-verifiable facts.

### Package convention

Each Ash extension should ship:

```text
usage-rules.md
usage-rules/
  authoring.md
  runtime.md
  security.md
  troubleshooting.md
  migration.md
  skills/
    use-extension/
      SKILL.md
      references/
```

The package should additionally expose:

```elixir
def agent_metadata do
  %{
    semantic_namespaces: [...],
    diagnostic_codes: [...],
    mix_tasks: [...],
    safe_runtime_tools: [...],
    dangerous_runtime_tools: [...],
    examples: [...]
  }
end
```

The package-authored files should explain intent, preferred patterns, dangerous shortcuts and operational workflows. Generated content should provide exact symbols, versions, source locations and installed extension capabilities.

### Validation

Add CI checks for:

- Broken module and function references.
- Rules referencing removed DSL entities.
- Examples that no longer compile.
- Undocumented public DSL sections and options.
- Missing security guidance for mutating tools.
- Skills that advertise unavailable dependencies.
- Rules that contradict generated action contracts.

This converts UsageRules from passive prose into a partially executable documentation discipline.

### Context selection

Agents should not receive all Ash documentation on every prompt. The semantic service should map the current file, symbol, error or task to relevant rule fragments.

For example:

```json
{
  "symbol": "MyApp.Accounts.User.create",
  "recommended_rules": [
    "ash:actions",
    "ash:authorization",
    "ash_postgres:migrations",
    "my_app:identity_management"
  ]
}
```

UsageRules already supports sub-rules, dependency selection, linking rather than inlining, package skills and composed framework skills. Semantic retrieval is therefore an extension of the existing model rather than a replacement.

## Clarity integration

Clarity is the strongest existing candidate for the visual and graph-analysis surface. Its repository describes it as interactive introspection and visualization for Elixir, Ash and Phoenix projects.

### Immediate tie-ins

Implement Clarity vertices for:

- Spark extensions and DSL sections.
- Policies and policy checks.
- UsageRules documents, skills and their target symbols.
- MCP tools and their read/write capabilities.
- BPMN definitions, activities, gateways and events.
- Process versions and active instances.
- DMN decisions, tables, inputs, outputs and rule rows.
- FEEL expressions and referenced context paths.
- Compliance controls, evidence, obligations and attestations.
- Data classifications and retention policies.
- Generated code interfaces and LSP symbols.

Add edge types such as:

```text
action --authorized_by--> policy
action --starts--> process
process_task --invokes--> action
process_task --evaluates--> decision
decision_rule --reads--> attribute
decision_rule --produces--> outcome
control --evidenced_by--> audit_event
usage_rule --guides--> semantic_symbol
mcp_tool --operates_on--> semantic_symbol
generated_function --represents--> action
```


### Existing alignment

Clarity already has an open proposal for an ontology report generated from Ash resources, including terms, descriptions, types, sensitive flags, source links and documentation coverage. That is directly aligned with the proposed semantic manifest and enterprise ontology.

Its roadmap also includes:

- An Ash AI conversational interface exposing tool calls, prompt-based actions and graph information.
- Ash API introspection connecting routers and external APIs back to resources.
- Compliance export.
- Document and ExDoc exports.
- Live action execution.
- Search indexing and editor integration.

These should not become isolated Clarity features. They should consume the shared semantic query layer and runtime capability model.

### Recommended ownership

| Concern | Owner |
| :-- | :-- |
| Canonical Ash semantics | Spark/Ash |
| Graph representation and lenses | Clarity |
| Editor protocol | Expert integration |
| Runtime agent transport | Tidewave adapter |
| Agent guidance | UsageRules |
| Process/decision semantics | Ash Enterprise extensions |
| Security and capability policy | Shared agent-runtime package |

Clarity’s graph should be embeddable behind MCP tools such as:

- `semantic_neighbors`
- `semantic_path`
- `impact_analysis`
- `find_policy_path`
- `find_processes_using_action`
- `find_rules_reading_sensitive_data`
- `generate_architecture_view`
- `generate_compliance_evidence_map`

Clarity already supports vertex queries, neighbor traversal, shortest paths, provenance and filtered subgraphs, so these operations fit its current model.

## Enterprise scope

The Ash Enterprise scope substantially changes the type of tooling required. Ordinary code intelligence answers “what symbol is this?” Enterprise semantic tooling must also answer:

- What business outcome can this code produce?
- Why did this decision return this result?
- Which human or automated authority permitted it?
- Which version of the rule was in effect?
- What evidence proves the control operated?
- What happens to in-flight work if this definition changes?
- Can the decision table ever produce conflicting or missing results?
- Which tenants have diverged from the platform baseline?


### Processes

Process tooling should treat BPMN models as typed programs rather than opaque XML.

Required capabilities:

- Validate referenced actions, arguments and output mappings.
- Infer process variable schemas across tasks and gateways.
- Detect unreachable nodes and unhandled terminal states.
- Validate event and timer declarations.
- Check that human tasks have candidate-resolution and escalation behavior.
- Enforce maker-checker separation.
- Simulate processes using recorded or synthetic inputs.
- Compare versions and classify migration safety.
- Explain an active instance in business language.
- Export portable definitions and in-flight state.


### DMN and FEEL

DMN and FEEL require their own static-analysis workstream:

- Parse all input entries at publish time.
- Type FEEL expressions against Ash attributes and process variables.
- Validate decision input and output contracts.
- Detect overlapping rules for decidable domains.
- Detect incomplete decision tables.
- Represent undecidable cases as explicit proof obligations.
- Record matched rule identifiers.
- Explain rule selection and output derivation.
- Trace null and three-valued-logic behavior.
- Provide an editor with semantic completion and diagnostics.
- Run examples and conformance cases before publication.

The current Ash Enterprise assessment identifies several unresolved issues: no decision test panel, no integrated FEEL editor, no publish-time overlap or completeness analysis, incomplete matched-rule explanations, delayed input-entry parsing, tenant-baseline drift without merging, and no export path for in-flight state.[Ash Enterprise gap analysis](https://github.com/lukegalea/ash_enterprise/blob/main/docs/manifesto/07-what-we-do-not-have.md)

These are not peripheral UI issues. They define the critical path for a trustworthy agentic rules platform.

### Compliance

Compliance should be modeled as semantic and runtime evidence, not generated narrative.

A control should connect:

```text
requirement
  -> control
  -> enforcement mechanism
  -> semantic symbols
  -> runtime events
  -> evidence
  -> review or attestation
```

For example:

```text
SOX maker-checker control
  -> approval requirement
  -> BPMN human task + policy
  -> AccessRequest.approve
  -> completed task + authorized action
  -> immutable audit record
  -> quarterly control evidence
```

This graph lets Clarity visualize the control, runtime tools inspect evidence, and agents answer compliance questions without inferring controls from prose.

### Decision provenance

Every process or decision execution should produce a standardized provenance envelope:

```elixir
%{
  semantic_id: "...",
  definition_version: "...",
  tenant_id: "...",
  actor_id: "...",
  input_digest: "...",
  output_digest: "...",
  matched_rule_ids: [...],
  policy_decision_ids: [...],
  process_instance_id: "...",
  evidence_ids: [...],
  trace_id: "..."
}
```

Sensitive values should not be copied into the envelope by default. Digests, classifications, retention metadata and separately authorized evidence retrieval should be preferred.

## Security model

Runtime agent support creates a materially larger attack surface than language-server support. The platform should classify every operation.


| Class | Example | Default |
| :-- | :-- | :-- |
| Static read | Describe action contract | Enabled |
| Runtime read | Inspect process instance | Enabled in development |
| Data read | Execute authorized Ash query | Actor and tenant required |
| Simulation | Evaluate unpublished decision | Sandbox only |
| Reversible write | Create decision draft | Disabled unless configured |
| Irreversible write | Publish rules, approve task, purge data | Human confirmation and audit |
| Arbitrary execution | Evaluate Elixir code | Local development only |

Tidewave itself defaults remote access to disabled and provides origin controls intended to mitigate cross-origin and DNS-rebinding attacks. Ash-specific tools must add actor, tenant, authorization and data-classification controls rather than assuming localhost alone is an adequate boundary.

Required controls include:

- Capability allowlists per environment.
- Read-only defaults.
- Actor and tenant binding.
- Normal Ash authorization for data operations.
- No implicit `authorize?: false`.
- Confirmation tokens for writes.
- Tool-call audit records.
- Output redaction based on Ash sensitivity metadata.
- Time, row and memory limits.
- No dynamic atom creation from agent input.
- Sandbox-only process and decision simulation.
- Separate development and operations MCP profiles.
- Structured denial reasons that do not disclose protected data.


## Type-system integration

The semantic platform should maintain its own type algebra independent of any one Elixir checker.

Required distinctions include:

- Accepted input versus normalized value.
- Required versus optional versus defaulted.
- `nil` versus FEEL `null` versus absent input.
- Loaded versus potentially unloaded relationships.
- Authorized versus merely structurally valid values.
- Public versus sensitive values.
- Tenant-scoped identifiers.
- Process variables before and after each task.
- Decision outputs by hit policy.
- Success, domain error and framework error channels.

Backends can emit:

- Current Elixir typespecs.
- Expert diagnostics.
- Dialyzer-compatible generated contracts.
- Future native Elixir type signatures.
- JSON Schema for agent tools.
- TypeScript declarations for generated clients.
- DMN/FEEL editor schemas.

This avoids coupling Ash’s semantic precision to the release schedule or limitations of a single type checker.

## Delivery roadmap

### Phase 0: Program setup

**Duration:** 4–6 weeks

**Deliverables:**

- Semantic-platform RFC.
- Cross-project steering group.
- Representative application corpus.
- Tooling benchmark suite.
- Security threat model.
- Stable-ID design.
- Versioning and compatibility policy.
- Initial BPMN/DMN/FEEL type algebra.
- Tidewave and Clarity collaboration proposals.

**Exit criteria:**

- Ten representative Ash projects load successfully.
- Expected editor and agent queries are documented.
- No consumer-specific fields appear in the canonical IR.
- Security approves the runtime capability model.


### Phase 1: Semantic foundation

**Duration:** 8–12 weeks

**Deliverables:**

- `Spark.Semantic` public API.
- Versioned portable manifest.
- Source maps and stable IDs.
- Extension-contribution protocol.
- Incremental invalidation and caching.
- Accepted-input and normalized-value types.
- Manifest inspection and diff commands.

**Exit criteria:**

- Deterministic output across repeated builds.
- Every public resource entity maps to a source location.
- Extension-generated entities retain provenance.
- Unknown extensions degrade without corrupting the manifest.
- Manifest compatibility tests run across supported Ash versions.


### Phase 2: Developer tooling

**Duration:** 8–14 weeks, overlapping Phase 1

**Deliverables:**

- Expert parity with Spark ElixirSense completion.
- Hover, navigation, diagnostics and rename.
- Generated action/code-interface contracts.
- Typed filters, loads and relationship paths.
- Expansion preview.
- Dialyzer guidance, baselines and generated-boundary improvements.

**Exit criteria:**

- Completion parity on the benchmark corpus.
- Navigation accuracy above the program’s agreed threshold.
- No meaningful latency regression on large projects.
- Generated symbols navigate to semantic declarations.
- Diagnostics distinguish framework, extension and compiler sources.


### Phase 3: Clarity and UsageRules

**Duration:** 8–12 weeks

**Deliverables:**

- Clarity semantic-manifest importer.
- Process, decision, policy, usage-rule and MCP-tool vertices.
- Ontology and documentation-coverage views.
- UsageRules semantic-reference generation.
- Compiled example validation.
- Contextual rule selection.
- Graph-query API suitable for MCP.

**Exit criteria:**

- Clarity and Expert resolve the same stable IDs.
- Public DSL documentation coverage is measurable.
- Agent skills contain no broken semantic references.
- Impact analysis crosses code, process, rule and policy boundaries.
- Graph exports use a safe portable format.


### Phase 4: Read-only runtime agents

**Duration:** 8–12 weeks

**Deliverables:**

- Tidewave provider RFC or standalone adapter.
- Ash discovery and description tools.
- Query and authorization explanation.
- Clarity graph-query tools.
- Process-instance inspection.
- Decision evaluation in sandbox mode.
- Structured outputs and redaction.
- Tool-call audit records.

**Exit criteria:**

- All tools are read-only or sandboxed.
- Actor and tenant context are explicit.
- Sensitive fields are redacted by default.
- Agents can debug representative Ash failures without arbitrary evaluation.
- Every result links to semantic IDs and source locations.


### Phase 5: Enterprise verification

**Duration:** 12–20 weeks

**Deliverables:**

- FEEL parser and type integration.
- Publish-time decision validation.
- Overlap and completeness analysis.
- Proof-obligation framework.
- Matched-rule and null-propagation explanations.
- Process variable typing.
- Process simulation.
- Tenant drift analysis.
- Definition and in-flight-state export.
- Compliance-control and evidence graph.

**Exit criteria:**

- Malformed decision entries cannot publish.
- Decidable overlaps and gaps are reported before publication.
- Every production decision can identify its definition version and matched rules.
- Process simulation is isolated from production state.
- Compliance reports link controls to executable enforcement and evidence.
- Engine replacement can be tested against the same conformance corpus.


### Phase 6: Governed operations

**Duration:** Subsequent controlled rollout

**Deliverables:**

- Draft-management tools.
- Human-confirmed approvals and task completion.
- Rule publication workflow.
- Attestation and evidence review.
- Environment-specific capability profiles.
- Operations-focused agent skills.
- Incident replay and forensic timelines.

**Exit criteria:**

- No mutating tool can bypass Ash authorization.
- Every operation has attributable actor and tenant context.
- Irreversible operations require explicit confirmation.
- Audit and retention behavior is verified.
- Operations can disable the agent surface independently of the application.


## Planning epics

| Epic | Primary owner | Depends on |
| :-- | :-- | :-- |
| Semantic IR and versioning | Spark/Ash core | None |
| Stable source identity | Spark/Ash core | Semantic IR |
| Expert integration | DX team | Semantic query API |
| Type-contract generation | Type systems team | Semantic type algebra |
| Clarity projection | Clarity team | Portable manifest |
| UsageRules validation | Agent enablement team | Stable semantic IDs |
| Tidewave provider API | Runtime tooling team | Capability model |
| Ash runtime tools | Runtime tooling team | Semantic service |
| Process type analysis | Enterprise workflow team | Semantic type algebra |
| DMN/FEEL verification | Rules team | Parser and type algebra |
| Compliance evidence graph | Governance team | Clarity and provenance |
| Security and redaction | Platform security | All runtime epics |
| Conformance corpus | Quality engineering | All semantic engines |

## Team shape

A credible first-year team is approximately:

- Two Ash/Spark core engineers.
- Two Expert/editor engineers.
- One Clarity/graph engineer.
- Two runtime-agent engineers.
- Two BPMN/DMN/FEEL engineers.
- One security/compliance engineer.
- One developer-experience technical writer or agent-knowledge engineer.
- Shared product, design and quality support.

The sequencing matters more than the exact headcount. Runtime agent features should not outrun semantic identity, authorization, redaction and provenance.

## Build versus partner

| Area | Recommendation |
| :-- | :-- |
| Spark semantic API | Build and own |
| Expert integration | Contribute upstream |
| Clarity semantic graph | Partner closely and contribute upstream |
| UsageRules | Extend upstream |
| Tidewave transport and generic runtime tools | Partner upstream; avoid a fork |
| Ash-specific MCP tools | Build in a separate package |
| DMN/FEEL semantic analysis | Build around standards and conformance suites |
| Visual BPMN/DMN editors | Integrate existing editors |
| Compliance evidence model | Build as Ash Enterprise semantics |
| Full Elixir type checker | Do not build |
| Generic coding agent | Do not build initially |

## Key decisions

The following decisions should be ratified before implementation:

1. **Spark semantics are canonical.** Clarity, Expert, UsageRules and runtime tools are consumers.
2. **Stable semantic IDs cross all planes.** Source positions and module names alone are insufficient.
3. **UsageRules contain judgment, not duplicated schema.** Machine facts are linked or generated.
4. **Clarity is the graph and visualization layer, not the portable IR.**
5. **Tidewave is preferred as transport, but Ash tooling remains independently usable.**
6. **Runtime tools are read-only by default.**
7. **Business-rule publication requires static validation and executable examples.**
8. **Every enterprise execution emits provenance.**
9. **Compliance evidence is modeled, not narrated after the fact.**
10. **The platform owns a type algebra but not a competing Elixir type checker.**

## Program risks

| Risk | Mitigation |
| :-- | :-- |
| Each integration invents its own Ash model | Require all consumers to use the semantic protocol |
| Manifest becomes tied to current Spark structs | Use normalized, versioned DTOs and compatibility fixtures |
| Clarity and the manifest duplicate graphs | Define manifest as facts and Clarity as queryable projection |
| UsageRules become large and stale | Contextual retrieval, generated references and validation |
| Tidewave upstream rejects provider extensibility | Maintain a standalone MCP adapter with compatible semantics |
| Agents bypass policy through generic evaluation | Prefer constrained Ash tools; disable arbitrary evaluation outside local development |
| Decision explanations disagree with the actual engine | Require the engine execution to emit matched-rule provenance |
| Rules analysis promises certainty for undecidable expressions | Emit explicit proof obligations and runtime checks |
| Tenant customization becomes unmergeable | Add semantic diffs, migration obligations and explicit fork governance |
| Native Elixir typing evolves incompatibly | Keep backend-independent Ash type algebra |
| Enterprise tooling becomes a monolith | Separate semantic core, graph, transport and extension packages |

## Success measures

The program should track outcomes rather than feature counts:

- Time to first accurate completion after opening a project.
- Completion relevance within Spark DSL contexts.
- Navigation accuracy for generated symbols.
- Percentage of public semantic entities with source ranges and documentation.
- Percentage of generated interfaces with precise contracts.
- Agent task success with and without semantic/runtime tools.
- Reduction in arbitrary `project_eval` calls when constrained tools exist.
- Percentage of decision defects caught before publication.
- Percentage of decision executions with matched-rule explanations.
- Percentage of process instances exportable or migration-classified.
- Percentage of compliance controls connected to executable enforcement and evidence.
- Runtime tool calls rejected for missing actor, tenant or capability context.
- Cross-version manifest compatibility.


## First planning increment

The first increment should produce five concrete artifacts:

1. A semantic-manifest RFC with Ash, Spark, Clarity, Expert, UsageRules and enterprise examples.
2. A working prototype exporting one resource—including actions, policy references and source maps—to portable JSON.
3. An Expert prototype consuming that artifact for one completion and one diagnostic.
4. A Clarity importer displaying the same stable symbols and relationships.
5. A read-only MCP prototype answering `ash_describe_action` and returning the same stable IDs.

That vertical slice proves the architecture before the team invests in complete editor support, runtime execution or enterprise verification. It also forces the most important integration decision early: whether all surfaces can share one semantic contract rather than reproducing Ash introspection independently.

<span style="display:none">[^2_1][^2_10][^2_11][^2_12][^2_13][^2_14][^2_15][^2_16][^2_17][^2_18][^2_19][^2_2][^2_20][^2_21][^2_22][^2_23][^2_24][^2_25][^2_26][^2_27][^2_28][^2_29][^2_3][^2_30][^2_31][^2_32][^2_33][^2_34][^2_4][^2_5][^2_6][^2_7][^2_8][^2_9]</span>

<div align="center">⁂</div>

[^2_1]: https://arxiv.org/pdf/2408.17351.pdf

[^2_2]: http://arxiv.org/pdf/2305.13380.pdf

[^2_3]: https://arxiv.org/pdf/2408.10082.pdf

[^2_4]: https://arxiv.org/html/2501.17126v1

[^2_5]: https://arxiv.org/pdf/2208.12214v2.pdf

[^2_6]: https://arxiv.org/html/2408.10082

[^2_7]: https://github.com/tidewave-ai/tidewave_phoenix

[^2_8]: https://hexdocs.pm/usage_rules/1.0.0-rc.0/readme.html

[^2_9]: https://hex.pm/packages/usage_rules/0.1.15/files/README.md

[^2_10]: https://hex.pm/packages/usage_rules/0.1.12

[^2_11]: https://hex.pm/packages/usage_rules/0.1.2

[^2_12]: https://hex.pm/packages/usage_rules/0.1.14/files/README.md

[^2_13]: https://hexdocs.pm/clarity/Clarity.html

[^2_14]: https://hex.pm/packages/clarity

[^2_15]: https://hex.pm/packages/usage_rules/0.1.23

[^2_16]: https://hexdocs.pm/tidewave/0.1.8/mcp.html

[^2_17]: https://hashrocket.com/blog/posts/supercharging-ai-assisted-development-in-phoenix-applications

[^2_18]: https://hexdocs.pm/tidewave/0.1.5/mcp.html

[^2_19]: https://hex.pm/packages/mishka_chelekom/0.0.10-alpha.3/files/usage-rules.md

[^2_20]: https://elixirforum.com/t/usage-rules-a-tool-for-synchronizing-llm-rules-files-with-your-dependencies/70991/

[^2_21]: https://hexdocs.pm/tidewave/0.1.7/mcp.html

[^2_22]: https://f1000research.com/articles/4-1443/v1/pdf

[^2_23]: https://arxiv.org/html/2312.11729v1

[^2_24]: https://pmc.ncbi.nlm.nih.gov/articles/PMC6480938/

[^2_25]: https://github.com/tidewave-ai/tidewave_phoenix/blob/main/README.md

[^2_26]: https://git.elixir.toys/elixir-vibe/pi-elixir

[^2_27]: https://github.com/ash-project/usage_rules

[^2_28]: https://www.claudepluginhub.com/skills/vinnie357-elixir-plugins-languages-elixir/tidewave

[^2_29]: https://deepwiki.com/tidewave-ai/tidewave_phoenix/4.1-code-evaluation-tools

[^2_30]: https://github.com/oliver-kriska/claude-elixir-phoenix

[^2_31]: https://github.com/tidewave-ai

[^2_32]: https://ashweekly.substack.com/p/ash-weekly-issue-22

[^2_33]: https://json.media/blog/en/ash-weekly-18-recap

[^2_34]: https://hexdocs.pm/tidewave/0.1.2/mcp.html

