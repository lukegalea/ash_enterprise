defmodule AshEnterprise.SystemOne.JudgedState.Backfill do
  @moduledoc """
  Seals the judged text of observations recorded before it was sealed
  (S1-98): an operator act, run once after the deploy that started sealing
  (`mix ash_enterprise.system_one.seal_judged_state`).

  It considers the observations a person may still be asked about: those
  of a review-banded judgment with no person's verdict yet, with no sealed
  state, and never erased (`:tombstone_state`). For each, it finds the
  subject again and projects it the way the judge did:

    * a code unit, under the checkout at `:root` (the standing job's
      extraction, `AshEnterprise.Standards.Standing.find_unit/4`; only where
      `ash_agent_tools` is loaded);
    * a record with judged fields (`AshEnterprise.SystemOne.JudgedFields`),
      from its projection fields;
    * a licence dependency (`AshEnterprise.Licences.Rungs.judged_state/2`);
    * a match candidate (`AshEnterprise.Mdm.MatchObservation.state/1`).

  The state is sealed only when its digest equals the recorded
  `state_digest`: then it is the text that was judged. Otherwise the row is
  left as it is and counted as `changed`. A subject that cannot be found
  again, or a kind it does not know (an evidence packet), is counted as
  `unresolved`. The write is the ledger's `:seal_state` update, as the
  migration system actor, which only fills a state that is still empty, so
  a second run finds nothing to do.

  Without `apply?: true` nothing is written and no scope is opened: the
  counts say what a run would seal. The result holds counts only, never
  text.
  """

  require Ash.Query

  alias AshEnterprise.Accounts.Organization
  alias AshEnterprise.Audit.EventLog
  alias AshEnterprise.Platform.SystemActor
  alias AshEnterprise.SystemOne.{Banding, HumanVerdict, JudgedFields, JudgedState, Judgment}

  @type counts :: %{
          awaiting: non_neg_integer(),
          sealed: non_neg_integer(),
          changed: non_neg_integer(),
          unresolved: non_neg_integer(),
          shredded: non_neg_integer()
        }

  @empty %{awaiting: 0, sealed: 0, changed: 0, unresolved: 0, shredded: 0}

  @code_unit AshEnterprise.Standards.CodeUnit

  @doc """
  Runs the backfill over every tenant, or the one `:tenant` names. Options:
  `:apply?` (default false), `:root` (the checkout code units are read
  from, default the current directory), `:max_tokens` and
  `:reserve_tokens` (the standing job's chunking budget). Returns the
  counts; `sealed` is what was sealed, or on a dry run what would be.
  """
  @spec run(keyword()) :: counts()
  def run(opts \\ []) do
    opts
    |> tenants()
    |> Enum.reduce(@empty, fn tenant, counts ->
      tenant
      |> awaiting()
      |> Enum.reduce(counts, fn judgment, counts ->
        counts
        |> Map.update!(:awaiting, &(&1 + 1))
        |> Map.update!(backfill(judgment, tenant, opts), &(&1 + 1))
      end)
    end)
  end

  @doc """
  The observations the backfill considers in `tenant`: review-banded, no
  person's verdict, no sealed state, never tombstoned.
  """
  @spec awaiting(Ash.UUID.t()) :: [Judgment.t()]
  def awaiting(tenant) do
    read = [authorize?: false, tenant: tenant]

    ids =
      Banding
      |> Ash.Query.filter(band == ^:review)
      |> Ash.read!(read)
      |> Enum.flat_map(& &1.observation_ids)
      |> Enum.uniq()

    pending = ids -- (verdicted(ids, read) ++ tombstoned(ids))

    Judgment
    |> Ash.Query.filter(id in ^pending and is_nil(state_ciphertext))
    |> Ash.Query.sort(recorded_at: :asc)
    |> Ash.read!(read)
  end

  defp verdicted([], _read), do: []

  defp verdicted(ids, read) do
    HumanVerdict
    |> Ash.Query.filter(judgment_id in ^ids)
    |> Ash.read!(read)
    |> Enum.map(& &1.judgment_id)
  end

  # An erased payload is never written back: the erasure is the ledger's
  # audit event for the row.
  defp tombstoned([]), do: []

  defp tombstoned(ids) do
    EventLog
    |> Ash.Query.filter(
      resource == ^Judgment and action == ^:tombstone_state and record_id in ^ids
    )
    |> Ash.read!(authorize?: false)
    |> Enum.map(& &1.record_id)
  end

  defp backfill(judgment, tenant, opts) do
    case restate(judgment, tenant, opts) do
      {:ok, state, scope_id} ->
        cond do
          JudgedState.digest(state) != judgment.state_digest -> :changed
          Keyword.get(opts, :apply?, false) -> seal(judgment, state, tenant, scope_id)
          true -> :sealed
        end

      :error ->
        :unresolved
    end
  end

  defp seal(judgment, state, tenant, scope_id) do
    case JudgedState.seal(state, judgment.state_digest, tenant, scope_id) do
      {:ok, sealed} ->
        judgment
        |> Ash.Changeset.for_update(:seal_state, %{state_ciphertext: sealed},
          actor: SystemActor.migration(),
          tenant: tenant
        )
        |> Ash.update!()

        :sealed

      {:error, :shredded} ->
        :shredded

      {:error, :changed} ->
        :changed

      # The subject's own scope was never issued.
      {:error, _unknown_scope} ->
        :unresolved
    end
  end

  ## Finding the subject again, and projecting it as the judge did.
  ## `{:ok, state, subject_scope_id}` or `:error`.

  defp restate(judgment, tenant, opts) do
    with {:ok, module, name} <- question_ref(judgment.question_id) do
      restate(module, name, judgment, tenant, opts)
    end
  end

  defp restate(AshEnterprise.Mdm.MatchCandidate, :matches_the_golden, judgment, tenant, _opts) do
    with {:ok, candidate} <- read(AshEnterprise.Mdm.MatchCandidate, judgment.subject_id, tenant) do
      {:ok, AshEnterprise.Mdm.MatchObservation.state(candidate), nil}
    end
  end

  defp restate(AshEnterprise.Licences.Dependency, name, judgment, tenant, _opts) do
    with true <- name in AshEnterprise.Licences.Rungs.questions(),
         {:ok, dependency} <- read(AshEnterprise.Licences.Dependency, judgment.subject_id, tenant) do
      {:ok, AshEnterprise.Licences.Rungs.judged_state(name, dependency), nil}
    else
      _ -> :error
    end
  end

  defp restate(@code_unit, name, judgment, _tenant, opts), do: code_unit(name, judgment, opts)

  defp restate(module, name, judgment, tenant, _opts) do
    with %{} = field <- Enum.find(JudgedFields.fields(module), &(&1.name == name)),
         true <- JudgedFields.subject_type(module) == judgment.subject_type,
         {:ok, record} <- read(module, judgment.subject_id, tenant) do
      state_input = JudgedFields.state_input(field, &Map.get(record, &1))

      {:ok, JudgedFields.judged_state(module, field, state_input),
       Map.get(record, :erasure_scope_id)}
    else
      _ -> :error
    end
  end

  # Code units are read from a checkout by the standing job, which is
  # compiled only where ash_agent_tools is (dev and test).
  if Code.ensure_loaded?(AshAgentTools.CodeSubjects.Standing) do
    defp code_unit(name, judgment, opts) do
      question = AshEnterprise.Standards.Questions.fetch!(name)
      root = Keyword.get(opts, :root) || File.cwd!()
      chunking = Keyword.take(opts, [:max_tokens, :reserve_tokens])

      case AshEnterprise.Standards.Standing.find_unit(
             root,
             question,
             judgment.subject_id,
             chunking
           ) do
        {:ok, unit} -> {:ok, AshEnterprise.Standards.Standing.judged_state(question, unit), nil}
        {:error, :not_found} -> :error
      end
    end
  else
    defp code_unit(_name, _judgment, _opts), do: :error
  end

  defp read(resource, id, tenant) do
    case Ash.get(resource, id, tenant: tenant, authorize?: false, not_found_error?: false) do
      {:ok, %{} = record} -> {:ok, record}
      _ -> :error
    end
  end

  # The question id names the declaring module and the question; neither
  # becomes a new atom (law 10).
  defp question_ref("judgment:v0:" <> rest) do
    with [module_name, name] <- String.split(rest, "#judgments/", parts: 2),
         {:ok, module} <- existing_module(module_name),
         {:ok, name} <- existing_atom(name) do
      {:ok, module, name}
    else
      _ -> :error
    end
  end

  defp question_ref(_question_id), do: :error

  defp existing_module(name) do
    {:ok, Module.safe_concat([name])}
  rescue
    ArgumentError -> :error
  end

  defp existing_atom(name) do
    {:ok, String.to_existing_atom(name)}
  rescue
    ArgumentError -> :error
  end

  defp tenants(opts) do
    case Keyword.get(opts, :tenant) do
      nil -> Organization |> Ash.read!(authorize?: false) |> Enum.map(& &1.id)
      tenant -> [tenant]
    end
  end
end
