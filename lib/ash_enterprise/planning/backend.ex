defmodule AshEnterprise.Planning.Backend do
  @moduledoc """
  Solver backend behaviour (programme §3). Incubated here; moves to
  `AshPlanning.Backend` in the extracted package.

  A backend turns a `Problem` into a `SolveResult` through an opaque session
  reference. Honesty rules every backend must honour:

  * `:infeasible` only when the solver *proved* unsatisfiability. A timeout with
    an incumbent is `:feasible` + `complete?: false` + `optimality: :none`; a
    timeout without one is `:unknown`.
  * `optimality: :proven` only with a solver optimality certificate.
  * Numeric values (objectives, assignments) are `Decimal`, never `Float`.
  """

  @capability_keys [
    :integer_variables,
    :optional_intervals,
    :cumulative,
    :no_overlap,
    :time_windows,
    :precedence,
    :objective_bound,
    :warm_start,
    :routing
  ]

  @doc "The nine v1 capability keys."
  @spec capability_keys() :: [atom()]
  def capability_keys, do: @capability_keys

  defmodule Problem do
    @moduledoc "What a backend is asked to solve: model/checker locations, data, limits."
    @enforce_keys [:model_path]
    defstruct [:model_path, :checker_path, data: %{}, limits: %{}, solver: "gecode", opts: %{}]

    @type t :: %__MODULE__{
            model_path: Path.t(),
            checker_path: Path.t() | nil,
            data: map() | keyword(),
            limits: map(),
            solver: String.t(),
            opts: map()
          }
  end

  defmodule Error do
    @moduledoc "Backend failure. `kind` is a closed set; `details` never carries secrets."
    @enforce_keys [:kind]
    defstruct [:kind, :message, details: %{}]

    @type kind ::
            :invalid_model
            | :invalid_problem
            | :resource_governor_unavailable
            | :limit_exceeds_ceiling
            | :solver_unavailable
            | :resource_exhausted
            | :runtime
            | :backend_crashed

    @type t :: %__MODULE__{kind: kind(), message: String.t() | nil, details: map()}
  end

  defmodule SolveResult do
    @moduledoc """
    Terminal solve outcome. `payload.candidates` hold decimal-exact assignment
    maps; checker verdicts ride along per candidate but are *recorded*, not
    judged, here (the check pipeline owns judgement).
    """
    @enforce_keys [:status]
    defstruct [
      :status,
      complete?: false,
      optimality: :none,
      outcome_reason: :normal,
      payload: %{candidates: []},
      stats: %{}
    ]

    @type t :: %__MODULE__{
            status: :feasible | :infeasible | :unknown,
            complete?: boolean(),
            optimality: :proven | :none,
            outcome_reason: atom(),
            payload: %{candidates: [map()]},
            stats: map()
          }
  end

  @type session_ref :: term()
  @type status :: %{
          stage: :compiling | :solving,
          solution_count: non_neg_integer(),
          running_time_ms: non_neg_integer()
        }

  @callback capabilities() :: %{required(atom()) => boolean()}
  @callback start(Problem.t() | map(), keyword()) :: {:ok, session_ref()} | {:error, Error.t()}
  @callback await(session_ref(), timeout()) :: {:ok, SolveResult.t()} | {:error, Error.t()}
  @callback status(session_ref()) :: {:ok, status()} | {:error, :not_running}
  @callback cancel(session_ref()) :: :ok | {:error, :not_running | {:survivors, [pos_integer()]}}
end
