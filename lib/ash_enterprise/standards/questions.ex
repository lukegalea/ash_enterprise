# Compiled only when ash_agent_tools is loaded (dev and test); see
# AshEnterprise.Standards.
if Code.ensure_loaded?(AshAgentTools.CodeSubjects.Fragment) do
  defmodule AshEnterprise.Standards.Questions do
    @moduledoc """
    The twenty-three confirmed standards questions as data: the clause each
    one asks about, where its standard is written, the projection it sees,
    the unit kinds and paths it is asked over, and which answers are
    violations.

    | Question | Clause | Projection |
    |---|---|---|
    | `no_forbid_if_for_row_access` | CLAUDE.md non-negotiable 2 | `PolicyView` |
    | `policy_check_never_queries` | CLAUDE.md non-negotiable 3 | `PolicyView` |
    | `handle_event_authorizes` | iron law 11 | `ModuleHeader` |
    | `comments_are_durable_facts_only` | iron law 26 | `Text` |
    | `association_query_strategy` | iron law 06 | `ModuleHeader` |
    | `oban_args_string_keyed` | iron law 08 | `ModuleHeader` |
    | `stores_ids_not_structs` | iron law 09 | `ModuleHeader` |
    | `third_party_api_wrapped` | iron law 20 | `FacadeView` |
    | `hs1_…` to `hs8_…` | HOUSE-STYLE.md HS-1 to HS-8 | `Text` |
    | `hs9_interface_copy_languages` | HOUSE-STYLE.md HS-9 | `ModuleHeader` |
    | `policy_check_calls_no_model` | ADR 0038, policy checks | `PolicyView` |
    | `actor_context_build_calls_no_model` | ADR 0038, the ActorContext build | `ModuleHeader` |
    | `feel_or_dmn_evaluation_calls_no_model` | ADR 0038, FEEL and DMN | `ModuleHeader` |
    | `rules_evaluation_makes_no_live_model_call` | ADR 0038, ash_rules and guard-path fact builders | `ModuleHeader` |
    | `projector_calls_no_model` | ADR 0038, projectors | `ModuleHeader` |
    | `calculation_calls_no_model` | ADR 0038, calculations | `ModuleHeader` |

    The six ADR 0038 questions each ask about one kind of component, and
    `AshEnterprise.Standards.Candidates.component/1` decides which kind a
    unit is. `calculation_calls_no_model` is advisory even by its own
    standard: ADR 0038 says "avoid" for calculations, not "never".

    ## What a fact's `in` means

    The facts table stores `holds` per subject and question: `in` when the
    admitted value equals the question's `holds_value`. Every yes/no
    question is worded so that `true` is compliant, so for those `in` means
    compliant. The two choice questions each have one forbidden option
    (`joins_has_many`, `not_done`), and that option is their `holds_value`:
    for them `in` means the unit takes the forbidden option. `violation?/2`
    reads the admitted value directly, so a filter for violations never
    depends on the polarity.

    `roll_up` follows from the polarity: a unit judged in chunks is
    compliant only when every chunk is (`:all` over yes/no questions), and
    takes the forbidden option when any chunk does (`:any` over the choice
    questions).
    """

    alias AshEnterprise.Standards.Projections.{FacadeView, ModuleHeader, PolicyView, Text}

    @code_paths ["lib"]
    @doc_paths ["docs", "lib", "README.md"]

    @noul %{holds_value: true, violations: [false], roll_up: :all}

    @questions [
                 Map.merge(@noul, %{
                   name: :no_forbid_if_for_row_access,
                   clause: "std-no-forbid-if-row-access",
                   source: "CLAUDE.md, non-negotiable 2",
                   projection: PolicyView,
                   kinds: [:dsl_entity, :function],
                   paths: @code_paths
                 }),
                 Map.merge(@noul, %{
                   name: :policy_check_never_queries,
                   clause: "std-policy-checks-never-query",
                   source: "CLAUDE.md, non-negotiable 3",
                   projection: PolicyView,
                   kinds: [:function],
                   paths: @code_paths
                 }),
                 Map.merge(@noul, %{
                   name: :handle_event_authorizes,
                   clause: "std-law-11-authorize-handle-event",
                   source: "iron law 11",
                   projection: ModuleHeader,
                   kinds: [:function],
                   paths: @code_paths
                 }),
                 Map.merge(@noul, %{
                   name: :comments_are_durable_facts_only,
                   clause: "std-law-26-comments-not-commit-messages",
                   source: "iron law 26",
                   projection: Text,
                   kinds: [:function, :dsl_entity],
                   paths: @code_paths
                 }),
                 %{
                   name: :association_query_strategy,
                   clause: "std-law-06-has-many-queries",
                   source: "iron law 06",
                   projection: ModuleHeader,
                   kinds: [:function],
                   paths: @code_paths,
                   holds_value: "joins_has_many",
                   violations: ["joins_has_many"],
                   roll_up: :any
                 },
                 Map.merge(@noul, %{
                   name: :oban_args_string_keyed,
                   clause: "std-law-08-oban-args-string-keyed",
                   source: "iron law 08",
                   projection: ModuleHeader,
                   kinds: [:function],
                   paths: @code_paths
                 }),
                 Map.merge(@noul, %{
                   name: :stores_ids_not_structs,
                   clause: "std-law-09-ids-not-structs",
                   source: "iron law 09",
                   projection: ModuleHeader,
                   kinds: [:function],
                   paths: @code_paths
                 }),
                 Map.merge(@noul, %{
                   name: :third_party_api_wrapped,
                   clause: "std-law-20-wrap-third-party-apis",
                   source: "iron law 20",
                   projection: FacadeView,
                   kinds: [:function],
                   paths: @code_paths
                 })
               ] ++
                 (for {name, n} <- [
                        hs1_lead_with_outcome_or_ask: 1,
                        hs2_keep_it_short: 2,
                        hs3_use_plain_words: 3,
                        hs4_claim_only_built_and_proven: 4,
                        hs5_promise_only_agreed_to: 5,
                        hs6_no_novelty_claims: 6,
                        hs7_never_invent_name_feature_or_date: 7,
                        hs8_no_internal_shorthand_for_outside: 8
                      ] do
                    Map.merge(@noul, %{
                      name: name,
                      clause: "std-hs-#{n}",
                      source: "HOUSE-STYLE.md, HS-#{n}",
                      projection: Text,
                      kinds: [:doc_paragraph],
                      paths: @doc_paths
                    })
                  end) ++
                 [
                   %{
                     name: :hs9_interface_copy_languages,
                     clause: "std-hs-9",
                     source: "HOUSE-STYLE.md, HS-9",
                     projection: ModuleHeader,
                     kinds: [:function],
                     paths: @code_paths,
                     holds_value: "not_done",
                     violations: ["not_done"],
                     roll_up: :any
                   }
                 ] ++
                 (for {name, clause, component, projection, kinds} <- [
                        {:policy_check_calls_no_model, "std-no-model-in-check", "policy checks",
                         PolicyView, [:function, :dsl_entity]},
                        {:actor_context_build_calls_no_model, "std-no-model-in-check",
                         "the ActorContext build", ModuleHeader, [:function]},
                        {:feel_or_dmn_evaluation_calls_no_model, "std-no-model-in-feel-or-rules",
                         "FEEL and DMN evaluation", ModuleHeader, [:function]},
                        {:rules_evaluation_makes_no_live_model_call,
                         "std-no-model-in-feel-or-rules",
                         "ash_rules evaluation and guard-path fact builders", ModuleHeader,
                         [:function]},
                        {:projector_calls_no_model, "std-no-model-in-projector",
                         "projector handlers", ModuleHeader, [:function]},
                        {:calculation_calls_no_model, "std-no-model-in-projector", "calculations",
                         ModuleHeader, [:function]}
                      ] do
                    Map.merge(@noul, %{
                      name: name,
                      clause: clause,
                      source: "ADR 0038, #{component}",
                      projection: projection,
                      kinds: kinds,
                      paths: @code_paths
                    })
                  end)

    @by_name Map.new(@questions, &{&1.name, &1})

    # Each question's generated judge action, spelled out at compile time.
    @judge_actions Map.new(@questions, &{&1.name, :"judge_#{&1.name}"})

    @doc "Every question, in clause order."
    @spec all() :: [map()]
    def all, do: @questions

    @doc "The question names, in clause order."
    @spec names() :: [atom()]
    def names, do: Enum.map(@questions, & &1.name)

    @doc "One question by name; raises on an unknown name."
    @spec fetch!(atom()) :: map()
    def fetch!(name), do: Map.fetch!(@by_name, name)

    @doc "The generated judge action for a question (`judge_<name>`)."
    @spec judge_action(atom()) :: atom()
    def judge_action(name), do: Map.fetch!(@judge_actions, name)

    @doc """
    The declared registry question (`AshJudgments.Registry.Info`) for a
    name: its `question_id`, hash, family and type.
    """
    @spec declared(atom()) :: struct()
    def declared(name),
      do: AshJudgments.Registry.Info.question(AshEnterprise.Standards.CodeUnit, name)

    @doc """
    A family's band-table score inputs: `"<question>__p_true"` for each of
    its yes/no questions, in clause order. These are the names
    `AshJudgments.Bridge.Dmn.inputs/2` flattens their answers to, and the
    `:score_input` of `AshJudgments.Calibration.ProposalDmn.render/2`. A
    choice question (`hs9_interface_copy_languages`) is left out: the
    family's calibration measured only its yes/no questions.
    """
    @spec score_inputs(atom() | String.t()) :: [String.t()]
    def score_inputs(family) do
      for %{name: name} <- @questions,
          question = declared(name),
          to_string(question.family) == to_string(family),
          question.type == AshAi.Evaluate.Noul,
          do: "#{question.name}__p_true"
    end

    @doc """
    Whether an admitted value violates the question's standard. Values
    arrive as the facts table stores them (`true`, `false`, `"not_done"`).
    """
    @spec violation?(atom() | map(), term()) :: boolean()
    def violation?(name, value) when is_atom(name), do: violation?(fetch!(name), value)
    def violation?(%{violations: violations}, value), do: normalise(value) in violations

    @doc """
    The rolled-up status that marks a violation: `:out` for a yes/no
    question (`in` is compliant), `:in` for a choice question (`in` is the
    forbidden option).
    """
    @spec violating_status(atom() | map()) :: :in | :out
    def violating_status(name) when is_atom(name), do: violating_status(fetch!(name))
    def violating_status(%{holds_value: true}), do: :out
    def violating_status(%{holds_value: _forbidden}), do: :in

    defp normalise(value) when is_boolean(value), do: value
    defp normalise("true"), do: true
    defp normalise("false"), do: false
    defp normalise(value) when is_atom(value) and not is_nil(value), do: Atom.to_string(value)
    defp normalise(value), do: value
  end
end
