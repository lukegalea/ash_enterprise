defmodule Battery.PlanningKit do
  @moduledoc """
  What the planning scenarios share: a candidate resource built from the
  package's own `AshPlanning.Fragment.Candidate` (on ETS, so a scenario owns
  its table and nothing persists), and the few pure helpers every scenario
  needs.

  The fragment is the contract under test: its `check_status`, `freshness` and
  `disposition` axes and the guards between them are the package's, not
  re-implemented here. The host half of a candidate (the freshness recheck and
  the writes) is each scenario's own, as it is each host's.

  Only ids, hashes and digests cross: a candidate's assignments name ids and
  integer slots, never a person or a value.
  """

  alias AshPlanning.Backend.Fake
  alias AshPlanning.{Candidate, Problem}

  defmodule Domain do
    @moduledoc false
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      resource Battery.PlanningKit.CandidateRow
    end
  end

  defmodule CandidateRow do
    @moduledoc """
    A planning candidate: the package fragment on an ETS table private to the
    process that first touches it (the test), so no scenario sees another's.
    """

    use Ash.Resource,
      domain: Battery.PlanningKit.Domain,
      data_layer: Ash.DataLayer.Ets,
      fragments: [AshPlanning.Fragment.Candidate]

    ets do
      private? true
    end

    # ETS cannot check an identity natively; the domain pre-checks the fragment's
    # one (`unique_run_index`) the way Postgres' unique index would.
    identities do
      identity :unique_run_index, [:run_id, :index], pre_check_with: Battery.PlanningKit.Domain
    end
  end

  @doc "Lowercase hex SHA-256."
  @spec sha(iodata()) :: String.t()
  def sha(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

  @doc "The SHA-256 of the canonical (RFC 8785) encoding of `term`."
  @spec canonical_hash(term()) :: String.t()
  def canonical_hash(term), do: sha(AshOpenLineage.Snapshot.CanonicalJSON.encode!(term))

  @doc """
  Solves through the package's Fake backend: the problem's scripted candidates
  come back as `AshPlanning.Candidate` structs, with the solve's completeness.
  """
  @spec solve!([map()], keyword()) :: {[Candidate.t()], AshPlanning.SolveResult.t()}
  def solve!(fake_candidates, data \\ []) do
    problem = %Problem{
      model_path: "battery_model.mzn",
      data: Map.merge(%{fake_candidates: fake_candidates}, Map.new(data))
    }

    {:ok, session} = Fake.start(problem, [])
    {:ok, result} = Fake.await(session, 1_000)
    {Enum.map(result.payload.candidates, &Candidate.from_map/1), result}
  end

  @doc """
  Proposes `assignments` as a candidate of `run_id`, checked `:correct` (the
  scenarios that need another check outcome say so).
  """
  @spec propose!(String.t(), non_neg_integer(), [map()], atom()) :: struct()
  def propose!(run_id, index, assignments, check_status \\ :correct) do
    CandidateRow
    |> Ash.Changeset.for_create(:propose, %{
      run_id: run_id,
      index: index,
      assignments: Jason.encode!(assignments)
    })
    |> Ash.create!()
    |> transition!(:record_check, %{check_status: check_status})
  end

  @doc "Runs one of the fragment's update actions, raising on refusal."
  @spec transition!(struct(), atom(), map(), keyword()) :: struct()
  def transition!(candidate, action, input \\ %{}, opts \\ []) do
    candidate
    |> Ash.Changeset.for_update(action, input, opts)
    |> Ash.update!()
  end

  @doc "Like `transition!/4`, returning the result instead of raising."
  @spec transition(struct(), atom(), map(), keyword()) :: {:ok, struct()} | {:error, term()}
  def transition(candidate, action, input \\ %{}, opts \\ []) do
    candidate
    |> Ash.Changeset.for_update(action, input, opts)
    |> Ash.update()
  end

  @doc "The candidate row as the store holds it now."
  @spec reload!(struct()) :: struct()
  def reload!(%{id: id}), do: Ash.get!(CandidateRow, id)
end
