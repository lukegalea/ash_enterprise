defmodule AshEnterprise.Licences.Rungs do
  @moduledoc """
  Which rung answers a licence subject (S1-63/AC-2).

  Law 4 of the judgment substrate: where a declaration can decide, a model
  must not. So `route/1` sends a release to a model only when its
  declaration cannot settle the questions:

    * **Declaration rung.** The release declares exactly one SPDX id the
      policy classifies. All nine questions are answered from the id
      (`AshEnterprise.Licences.DeclarationRung`) and nothing goes to a model.
      The one question a declaration cannot settle, the NOTICE check for an
      Apache-2.0 release, is read from the package contents when they have
      been read (`notice_file_present`), and is otherwise left pending.
    * **Model rung.** Anything else: no declaration, several ids, or an id
      the policy does not classify. The eight licence questions go to the
      model, which reads the release's own licence text and file names
      (`model_input/1`) and never its declaration. Whether the declaration
      is a valid SPDX id is not a model question: an empty declaration
      answers it (`true`); any other unclassified declaration is pending a
      person, as the policy's lic-7 requires.

  `judge/3` enforces the split: it refuses to send a question to a model
  when the route says the declaration (or the contents) answered it. The
  one exception is a calibration pass (`calibration?: true`), which asks the
  model about declared subjects on purpose, so its answers can be scored
  against the declaration's.
  """

  alias AshEnterprise.Licences.DeclarationRung
  alias AshEnterprise.Licences.Dependency
  alias AshEnterprise.SystemOne

  @questions [
    :package_licence_is_permissive,
    :package_licence_is_strong_copyleft,
    :package_licence_is_weak_copyleft,
    :package_licence_is_network_copyleft,
    :package_licence_requires_attribution,
    :package_requires_notice_file,
    :package_licence_declaration_invalid,
    :package_is_public_domain_dedication,
    :package_licence_has_use_restrictions
  ]

  @model_questions @questions -- [:package_licence_declaration_invalid]

  # Each question's generated judge action, spelled out at compile time.
  @judge_actions Map.new(@questions, &{&1, :"judge_#{&1}"})

  @type route :: %{
          rung: :declaration | :model,
          spdx_id: String.t() | nil,
          answers: %{atom() => boolean()},
          answered_by: %{atom() => :declaration | :package_contents},
          to_model: [atom()],
          pending: %{atom() => atom()}
        }

  @doc "The nine confirmed questions, in clause order (lic-1 to lic-9)."
  @spec questions() :: [atom()]
  def questions, do: @questions

  @doc "Routes one subject to the rung that answers it. Pure: no I/O, no model."
  @spec route(Dependency.t() | map()) :: route()
  def route(subject) do
    case DeclarationRung.declared_id(subject) do
      {:ok, spdx_id} -> declaration_route(subject, spdx_id)
      :none -> model_route(subject)
    end
  end

  defp declaration_route(subject, spdx_id) do
    {answers, answered_by, pending} =
      spdx_id
      |> DeclarationRung.answers()
      |> Enum.reduce({%{}, %{}, %{}}, fn
        {question, :needs_package_contents}, {answers, by, pending} ->
          case Map.get(subject, :notice_file_present) do
            present when is_boolean(present) ->
              {Map.put(answers, question, present), Map.put(by, question, :package_contents),
               pending}

            nil ->
              {answers, by, Map.put(pending, question, :needs_package_contents)}
          end

        {question, value}, {answers, by, pending} ->
          {Map.put(answers, question, value), Map.put(by, question, :declaration), pending}
      end)

    %{
      rung: :declaration,
      spdx_id: spdx_id,
      answers: answers,
      answered_by: answered_by,
      to_model: [],
      pending: pending
    }
  end

  defp model_route(subject) do
    {answers, answered_by, pending} =
      case Map.get(subject, :declared_licences) do
        [] ->
          {%{package_licence_declaration_invalid: true},
           %{package_licence_declaration_invalid: :declaration}, %{}}

        _unclassified ->
          {%{}, %{}, %{package_licence_declaration_invalid: :needs_person}}
      end

    %{
      rung: :model,
      spdx_id: nil,
      answers: answers,
      answered_by: answered_by,
      to_model: @model_questions,
      pending: pending
    }
  end

  @doc """
  What the model sees for a subject: the release's licence text and its
  top-level file names. Never the declaration, the package name or the
  version, so a model answer is a reading of the licence itself.
  """
  @spec model_input(Dependency.t() | map()) :: map()
  def model_input(subject) do
    %{
      "licence_text" => Map.get(subject, :licence_text),
      "package_files" => Map.get(subject, :package_files) || []
    }
  end

  @doc """
  Asks the model one question about one subject, through the question's
  generated judge action, and records the answer in the judgment ledger.

  Refuses (`{:error, {:answered_without_model, question}}`) when the route
  does not send that question to a model, unless `calibration?: true`.

  Options: `:actor` (required), `:tenant` (required), `:calibration?`,
  `:judgments` (extra judge-context entries, e.g. a test's `:req_llm`;
  the default transport is `AshEnterprise.SystemOne.DecisionWire`) and
  `:correlation_id`.
  """
  @spec judge(Dependency.t(), atom(), keyword()) :: {:ok, term()} | {:error, term()}
  def judge(%Dependency{} = subject, question, opts) when question in @questions do
    route = route(subject)
    calibration? = Keyword.get(opts, :calibration?, false)

    if calibration? or question in route.to_model do
      judgments =
        Map.merge(
          %{
            req_llm: SystemOne.DecisionWire,
            subject: %{type: "licence_dependency", id: subject.id},
            state_ref: %{"purpose" => if(calibration?, do: "calibration", else: "live")}
          },
          Keyword.get(opts, :judgments, %{})
        )

      input =
        judge_input(subject, question,
          actor: Keyword.fetch!(opts, :actor),
          tenant: Keyword.fetch!(opts, :tenant)
        )

      Ash.run_action(input,
        context:
          SystemOne.judge_context(
            tenant: Keyword.fetch!(opts, :tenant),
            correlation_id: Keyword.get(opts, :correlation_id),
            judgments: judgments,
            judged_state: judged_state(question, input)
          )
      )
    else
      {:error, {:answered_without_model, question}}
    end
  end

  @doc """
  The state a question's judge sees for a subject: `model_input/1` as the
  judge action's input, through the question's projection
  (`AshEnterprise.SystemOne.JudgedState.project/2`).
  """
  @spec judged_state(atom(), Dependency.t() | map() | Ash.ActionInput.t()) :: term()
  def judged_state(question, %Ash.ActionInput{} = input) when question in @questions do
    Dependency
    |> AshJudgments.Registry.Info.question(question)
    |> AshEnterprise.SystemOne.JudgedState.project(input)
  end

  def judged_state(question, subject) when question in @questions,
    do: judged_state(question, judge_input(subject, question, []))

  defp judge_input(subject, question, opts) do
    Ash.ActionInput.for_action(
      Dependency,
      Map.fetch!(@judge_actions, question),
      %{input: model_input(subject)},
      opts
    )
  end
end
