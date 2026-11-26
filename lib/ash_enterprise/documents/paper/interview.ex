defmodule AshEnterprise.Documents.Paper.Interview do
  @moduledoc """
  Ask only what a requirement cannot yet decide, and never ask twice (R1, R8).

  A kind may carry a requirement (`AshEnterprise.Documents.Paper.Kind`'s
  `requirement/0`, an `AshRules` module). Before a run renders, `check/3` evaluates it with
  `AshCompliance.status_for/2` — the requirement's own bundle passed as
  `:bundle`, so no active-bundle read, and the default
  `AshRules.Evaluator.Direct` evaluator, which reports a rule's unknowns
  rather than leaving them out — over the facts this module builds
  (`facts/2`, the `AshCompliance.FactBuilder` contract):

    * **Ground facts** come from the payload's typed facts (the requirement's
      `ground_facts/1`).
    * **Asked facts** — every predicate the requirement declares
      `missing: :unknown` — come from what a person answered, recorded in
      `AshEnterprise.SystemOne.Fact` under the kind's scope with the
      organization added (`%{"organization" => org_id, ...kind.scope(payload)}`)
      and read through `AshJudgments.Query.status/4` at the person grade,
      against the subject state digest of the payload as it is now
      (`digest/3`). `{:in, _}` and `{:out, _}` emit the answer; any
      `{:unknown, reason}` — no answer, an answer recorded below person grade,
      one given about data that has since changed (`:stale`), one past its
      `valid_until` (the kind's `valid_until/1`, `:expired`) — emits nothing,
      so the rule stays `:unknown`.

  The outcome, in order:

    * any rule `:unknown` → `{:blocked, {:missing_facts, entries}}`: one entry
      per absence the rule could not decide (`missing: :unknown` only — an
      absence the schema reads as false decided its rule, so it is never
      asked), each with the rule's id, its own message and evidence text, the
      question (the fact's description), why it is asked (`"no_fact"`,
      `"stale"`, `"expired"`, `"below_grade"`), and the scope and digest an
      answer is recorded under;
    * otherwise any rule that fired (or errored) →
      `{:blocked, {:requirement_failed, entries}}`;
    * otherwise, every rule compliant or not applicable → `:ok`.

  An unknown rule with no askable absence, an overall outcome that is not
  decided, or an evaluation that fails all block too: what cannot be shown
  satisfied is never read as satisfied.

  A rule stops at its first unknown, so answering one question can reveal
  the next: the interview is "the next missing facts, repeated until stable",
  one issue at a time.

  ## The digest

  The subject state digest is keyed (HMAC-SHA256,
  `AshPaper.Canonical.keyed_hash/2`, under
  `AshEnterprise.Documents.Paper.InterviewDigestKey`) over the scope (the
  organization and the kind's scope) and the payload's typed facts. The facts
  table is not sealed, and an unkeyed hash of a few amounts is a dictionary
  away from them. The same data gives the same digest, so a second document in
  the same scope reads the answer `:in`; changed data reads it `:stale` and
  asks again.
  """

  @behaviour AshCompliance.FactBuilder

  alias AshEnterprise.Documents.Paper
  alias AshEnterprise.Documents.Paper.InterviewDigestKey
  alias AshJudgments.Facts.Materialiser
  alias AshRules.Ir.{Fact, FactSchema, Var}

  @facts AshEnterprise.SystemOne.Fact
  @grade :person
  @decided [:compliant, :not_applicable]

  @typedoc "What `check/3` evaluates: the requirement, the scope it is asked in, the ground facts and the digest."
  @type subject :: %{
          requirement: module(),
          organization_id: Ash.UUID.t(),
          scope: map(),
          ground: [AshRules.Facts.triple()],
          digest: String.t()
        }

  @doc """
  Evaluates `kind`'s requirement against `payload` in `organization_id`:
  `:ok` when the kind has none or every rule is satisfied, else
  `{:blocked, reason}` (see the moduledoc).
  """
  @spec check(String.t(), AshPaper.Payload.t(), Ash.UUID.t()) :: :ok | {:blocked, term()}
  def check(kind, payload, organization_id) do
    with {:ok, module} <- Paper.kind(kind),
         requirement when not is_nil(requirement) <- module.requirement() do
      evaluate(subject(module, payload, organization_id))
    else
      nil -> :ok
      {:error, error} -> {:blocked, {:requirement_error, Exception.message(error)}}
    end
  end

  @doc "What `kind`'s requirement is evaluated over, for `payload` in `organization_id`."
  @spec subject(module(), AshPaper.Payload.t(), Ash.UUID.t()) :: subject()
  def subject(kind, payload, organization_id) do
    requirement = kind.requirement()
    kind_scope = kind.scope(payload)

    %{
      requirement: requirement,
      organization_id: organization_id,
      scope: scope(organization_id, kind_scope),
      ground: requirement.ground_facts(payload),
      digest: digest(organization_id, kind_scope, payload.facts)
    }
  end

  @doc "Evaluates `subject`'s requirement (`check/3` without the kind lookup)."
  @spec evaluate(subject()) :: :ok | {:blocked, term()}
  def evaluate(subject) do
    bundle = bundle(subject.requirement)
    asked = asked(bundle, subject)

    case AshCompliance.status_for(subject, bundle: bundle, fact_builder: __MODULE__, asked: asked) do
      {:ok, status} -> decide(bundle, status, asked, subject)
      {:error, reason} -> {:blocked, {:requirement_error, inspect(reason)}}
    end
  end

  @doc """
  The `AshCompliance.FactBuilder` callback: the ground facts, plus each asked
  predicate a current, person-grade answer decides. `opts[:asked]` carries the
  statuses `evaluate/1` already read; without it they are read here.
  """
  @impl AshCompliance.FactBuilder
  def facts(subject, opts) do
    asked =
      Keyword.get_lazy(opts, :asked, fn ->
        asked(bundle(subject.requirement), subject)
      end)

    answers =
      for {predicate, {decision, _fact}} <- asked, decision in [:in, :out] do
        {subject.requirement.subject(), predicate, decision == :in}
      end

    subject.ground ++ answers
  end

  @doc """
  `requirement`'s bundle as it is evaluated: IR-round-tripped like every
  seeded bundle (`AshEnterprise.Mdm.QualityProjector.active_bundle/1`), so its
  subjects carry the post-compile string spelling the fact builder emits
  (`AshCompliance.FactBuilder`'s first rule). The module's own `__bundle__/0`
  keeps the DSL's atoms, which no string-subject fact ever meets: every rule
  would read as not applicable and nothing would ever be asked.
  """
  @spec bundle(module()) :: AshRules.Ir.Bundle.t()
  def bundle(requirement) do
    requirement.__bundle__() |> AshRules.Ir.encode!() |> AshRules.Ir.decode!()
  end

  @doc """
  The predicates of `bundle` a person answers: the ones declared
  `missing: :unknown` (an absence there can only be decided by asking).
  """
  @spec askable(AshRules.Ir.Bundle.t()) :: [atom()]
  def askable(bundle) do
    for %Fact{missing: :unknown, name: name} <- bundle.fact_schema.facts, do: name
  end

  @doc """
  Whether a person may answer `predicate` (a string) for `kind`: `{:ok, name}`
  with the declared predicate, `{:error, :no_requirement}` when the kind has
  none, `{:error, :undeclared}` when its bundle does not declare it, or
  `{:error, :not_asked}` when it is declared but decided by the payload.
  """
  @spec answerable(String.t(), String.t()) ::
          {:ok, atom()} | {:error, :no_requirement | :undeclared | :not_asked}
  def answerable(kind, predicate) when is_binary(predicate) do
    with requirement when not is_nil(requirement) <- Paper.requirement(kind),
         bundle = bundle(requirement),
         %Fact{} = fact <- Enum.find(bundle.fact_schema.facts, &(to_string(&1.name) == predicate)) do
      if fact.name in askable(bundle), do: {:ok, fact.name}, else: {:error, :not_asked}
    else
      nil ->
        if Paper.requirement(kind), do: {:error, :undeclared}, else: {:error, :no_requirement}
    end
  end

  @doc """
  The answer to a recorded question as it stands now: `AshJudgments.Query.status/4`
  for the question's predicate in its scope, against the digest it was asked
  under, at the person grade.
  """
  @spec status_of(map(), Ash.UUID.t()) :: {:in | :out, term()} | {:unknown, atom()}
  def status_of(
        %{"predicate" => predicate, "scope" => scope, "digest" => digest},
        organization_id
      ) do
    read(predicate, organization_id, scope, digest)
  end

  @doc """
  Records `answer` (an `AshEnterprise.Documents.PaperAnswer`) as the asked
  fact, at person grade, through `AshJudgments.Facts.Materialiser` — the facts
  table's one write path. The answer is the admission: its id is the fact's
  `admission_id`.
  """
  @spec record(struct()) :: {:ok, atom()} | {:error, term()}
  def record(answer) do
    Materialiser.materialise_verdict(
      %{
        subject: fact_subject(answer.organization_id),
        predicate: answer.predicate,
        value: answer.holds,
        holds: answer.holds,
        scope: answer.scope,
        subject_state_digest: answer.subject_state_digest,
        valid_until: answer.valid_until,
        admission_id: answer.id
      },
      resource: @facts
    )
  end

  @doc "The subject an organization's asked facts are recorded about."
  @spec fact_subject(Ash.UUID.t()) :: map()
  def fact_subject(organization_id), do: %{"type" => "organization", "id" => organization_id}

  @doc "The scope an asked fact is recorded and read in: the kind's scope and the organization."
  @spec scope(Ash.UUID.t(), map()) :: map()
  def scope(organization_id, kind_scope) when is_map(kind_scope),
    do: Map.put(kind_scope, "organization", organization_id)

  @doc """
  The keyed digest of the payload's typed facts in `organization_id` and the
  kind's scope (see the moduledoc).
  """
  @spec digest(Ash.UUID.t(), map(), map()) :: String.t()
  def digest(organization_id, kind_scope, facts) when is_map(kind_scope) do
    AshPaper.Canonical.keyed_hash(
      digest_key(),
      organization_id |> scope(kind_scope) |> Map.put("facts", facts)
    )
  end

  @doc """
  Until when an answer recorded in `scope` for `kind` holds (the kind's
  `valid_until/1`, over the scope without the organization), or nil.
  """
  @spec valid_until(String.t(), map()) :: DateTime.t() | nil
  def valid_until(kind, scope) when is_map(scope) do
    case Paper.kind(kind) do
      {:ok, module} -> module.valid_until(Map.delete(scope, "organization"))
      {:error, _unknown} -> nil
    end
  end

  # ── evaluation ─────────────────────────────────────────────────────────

  defp asked(bundle, subject) do
    Map.new(askable(bundle), fn name ->
      {name, read(to_string(name), subject.organization_id, subject.scope, subject.digest)}
    end)
  end

  defp read(predicate, organization_id, scope, digest) do
    term = fact_subject(organization_id)

    AshJudgments.Query.status(@facts, term, predicate,
      scope: scope,
      min_grade: @grade,
      current_digests: %{term => digest}
    )
  end

  defp decide(bundle, status, asked, subject) do
    {unknown, fired} =
      status.rules
      |> Enum.reject(&(&1.status in @decided))
      |> Enum.split_with(&(&1.status == :unknown))

    cond do
      unknown != [] -> missing(bundle, unknown, status.missing_facts, asked, subject)
      fired != [] -> {:blocked, {:requirement_failed, Enum.map(fired, &failure(bundle, &1))}}
      status.status in @decided -> :ok
      true -> {:blocked, {:requirement_undecided, [to_string(status.status)]}}
    end
  end

  # Only absences the schema says cannot be known: `missing_facts` also lists
  # absences a rule decided by reading them as false, which ask nothing.
  defp missing(bundle, unknown, missing_facts, asked, subject) do
    absences = Enum.filter(missing_facts, &unknowable?(bundle, &1))

    entries =
      for verdict <- unknown,
          rule = rule(bundle, verdict.rule_id),
          {probe_subject, name, _value} <- absences,
          probes?(rule, probe_subject, name),
          uniq: true do
        entry(bundle, rule, probe_subject, name, asked, subject)
      end

    case entries do
      [] -> {:blocked, {:requirement_undecided, Enum.map(unknown, & &1.rule_id)}}
      entries -> {:blocked, {:missing_facts, entries}}
    end
  end

  defp unknowable?(bundle, {_subject, name, _value}) do
    match?({:ok, %Fact{missing: :unknown}}, FactSchema.fetch(bundle.fact_schema, name))
  end

  defp probes?(nil, _subject, _name), do: false

  defp probes?(rule, subject, name) do
    Enum.any?(rule.applicability ++ rule.failure_conditions, fn predicate ->
      predicate.name == name and
        (predicate.subject == subject or is_struct(predicate.subject, Var))
    end)
  end

  defp entry(bundle, rule, probe_subject, name, asked, subject) do
    {:ok, fact} = FactSchema.fetch(bundle.fact_schema, name)

    %{
      "predicate" => to_string(name),
      "subject" => to_string(probe_subject),
      "rule" => rule.id,
      "message" => rule.message || rule.name,
      "evidence" => rule.evidence,
      "question" => fact.description,
      "reason" => reason(Map.get(asked, name)),
      "scope" => subject.scope,
      "digest" => subject.digest
    }
  end

  defp reason({:unknown, reason}), do: to_string(reason)
  defp reason(_not_asked), do: "no_fact"

  defp failure(bundle, verdict) do
    rule = rule(bundle, verdict.rule_id)

    %{
      "rule" => verdict.rule_id,
      "status" => to_string(verdict.status),
      "message" => verdict.message || (rule && (rule.message || rule.name)),
      "gap" => verdict.gap,
      "severity" => verdict.severity && to_string(verdict.severity)
    }
  end

  defp rule(bundle, id), do: Enum.find(bundle.rules, &(&1.id == id))

  defp digest_key, do: InterviewDigestKey.key()
end
