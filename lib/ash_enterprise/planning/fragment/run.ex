defmodule AshEnterprise.Planning.Fragment.Run do
  @moduledoc """
  The pure shape of one planning run: a request to propose assignments over one pinned
  model version, binding and snapshot, and what came of it.

  Attributes, actions, validations and identities only. Tenancy, ownership, sealing,
  audit, policies, relationships and the `postgres` block are the host's (the host seals
  `problem_payload` and `result_payload`, which this fragment declares `sensitive?`); the
  fragment is written to move into the `ash_planning` package unchanged apart from its
  name.

  ## Axes, kept apart

  | Column | Values | Written by |
  |---|---|---|
  | `preparation_status` | `:pending`, `:prepared`, `:needs_input`, `:preparation_failed` | `prepare` |
  | `solve_status` | `:optimal`, `:feasible`, `:infeasible`, `:unknown`, `:invalid_model`, `:backend_failed`, `:cancelled`; `nil` until there is an outcome | `record_result` |
  | `complete?` | `true` only when the search ran to its end | `record_result` |
  | `optimality` | `:optimal`, `:bound`, `:none` | `record_result` |
  | `world` | `:operational`, `:scenario` | `request` |

  `Run.ResultAxes` refuses the combinations the programme forbids: nothing but `:optimal`
  carries `optimality: :optimal` (a checker is never an optimality certificate); a timeout
  with no incumbent is `:unknown`, never `:infeasible`; `:infeasible` is `complete?: true`
  (UNSAT established); a run that did not finish its search is `complete?: false`.

  ## No clear numbers

  There is no objective, bound or gap column. They are decimals, and they live inside the
  sealed `result_payload`. `stats` holds structural counts and timings only.

  ## Lease

  `start` takes a lease (`lease_epoch` + 1, `lease_expires_at`); `renew_lease` and
  `record_result` are fenced by the epoch they were given, so a session that lost its lease
  cannot write over the run that replaced it.

  ## Not here

  `model_version_id`, `binding_id` and `erasure_scope_id` are plain columns here; the
  host's `belongs_to` relationships give them their meaning. `invocation_id` is nullable:
  a run started through a governed invocation names it, a person's self-service request
  does not.
  """

  use Spark.Dsl.Fragment, of: Ash.Resource

  alias AshEnterprise.Planning.Fragment.Run.{Changes, Validations}

  @solve_statuses [
    :optimal,
    :feasible,
    :infeasible,
    :unknown,
    :invalid_model,
    :backend_failed,
    :cancelled
  ]

  @outcome_reasons [
    :lease_lost,
    :time_limit,
    :solution_timeout,
    :fzn_timeout,
    :memory_limit,
    :heavy_solve_busy,
    :resource_governor_unavailable,
    :model_missing,
    :backend_error,
    :orphan_swept
  ]

  attributes do
    uuid_primary_key :id

    attribute :model_version_id, :uuid do
      allow_nil? false
      public? true
      description "The pinned model version."
    end

    attribute :binding_id, :uuid do
      allow_nil? false
      public? true
      description "The binding the run was requested under."
    end

    attribute :snapshot_digest, :string do
      public? true
      constraints match: ~r/\A[0-9a-f]{64}\z/
      description "The snapshot envelope's digest (lowercase hex SHA-256). Nil until prepared."
    end

    attribute :knowledge_cutoff, :utc_datetime_usec do
      public? true

      description """
      The instant the run's inputs, binding and definitions are read as of. Nil until
      `prepare`, which requires it. Replay resolves the binding as of this instant and never
      re-reads the live one.
      """
    end

    attribute :problem_payload, :binary do
      public? false
      sensitive? true
      description "The bounded problem document handed to the solver. Sealed by the host."
    end

    attribute :result_payload, :binary do
      public? false
      sensitive? true
      description "The solve result, objective, bound and gap included. Sealed by the host."
    end

    attribute :preparation_status, :atom do
      allow_nil? false
      public? true
      default :pending
      constraints one_of: [:pending, :prepared, :needs_input, :preparation_failed]
      description "Preparation axis, owned by the snapshot builder."
    end

    attribute :solve_status, :atom do
      public? true
      constraints one_of: @solve_statuses
      description "Solve axis, owned by the backend. Nil until there is an outcome."
    end

    attribute :complete?, :boolean do
      allow_nil? false
      public? true
      default false
      description "True only when the search ran to its end; false means a limit stopped it."
    end

    attribute :optimality, :atom do
      allow_nil? false
      public? true
      default :none
      constraints one_of: [:optimal, :bound, :none]
      description "`:optimal` only on a solver optimality certificate; never from a checker."
    end

    attribute :outcome_reason, :atom do
      public? true
      constraints one_of: @outcome_reasons
      description "Why a run ended without an answer: a code, never free text."
    end

    attribute :world, :atom do
      allow_nil? false
      public? true
      default :operational
      constraints one_of: [:operational, :scenario]
    end

    attribute :scenario_ref, :string do
      public? true
      constraints max_length: 255
      description "The simulation-twin scenario a `:scenario` run is about."
    end

    attribute :backend, :map do
      public? true
      description "The backend identity: name, solver and version. Structural values only."
    end

    attribute :stats, :map do
      allow_nil? false
      public? true
      default %{}
      description "Structural counts and timings. No input or result values."
    end

    attribute :unresolved_inputs, {:array, :map} do
      allow_nil? false
      public? true
      default []

      description """
      Why preparation is `:needs_input`: one `%{"id" => …, "reason" => …}` per input, naming
      the source and a reason code. Never a value.
      """
    end

    attribute :cancellation_reason, :atom do
      public? true
      constraints one_of: [:requested, :operator, :shutdown]
      description "Set when a cancel was asked for; the session ends the run `:cancelled`."
    end

    attribute :requested_actor_id, :uuid do
      allow_nil? false
      public? true
      description "The person who asked."
    end

    attribute :lease_epoch, :integer do
      allow_nil? false
      public? true
      default 0
      constraints min: 0
      description "Bumped by every `start`; fences stale sessions."
    end

    attribute :lease_expires_at, :utc_datetime_usec do
      public? true
      description "When the session's lease lapses unless renewed."
    end

    attribute :session_pid, :string do
      public? true

      description "The solver session's identity, as text. Informational: the lease decides recovery."
    end

    attribute :invocation_id, :uuid do
      public? true
      description "The governed invocation that requested the run, when one did."
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  actions do
    defaults [:read]

    create :request do
      description "Ask for a solve over a model version and binding."
      accept [:binding_id, :model_version_id, :world, :scenario_ref]

      validate present(:scenario_ref),
        where: attribute_equals(:world, :scenario),
        message: "a scenario run names its scenario"

      validate absent(:scenario_ref),
        where: attribute_equals(:world, :operational),
        message: "an operational run has no scenario"

      change set_attribute(:requested_actor_id, actor(:id))
    end

    update :prepare do
      description "Record what the snapshot builder made of the inputs."

      accept [
        :preparation_status,
        :snapshot_digest,
        :knowledge_cutoff,
        :problem_payload,
        :stats,
        :unresolved_inputs
      ]

      require_atomic? false

      validate attribute_in(:preparation_status, [:prepared, :needs_input, :preparation_failed])

      validate present(:knowledge_cutoff),
        message: "preparation records the knowledge cutoff the inputs were read as of"

      validate present(:snapshot_digest),
        where: attribute_in(:preparation_status, [:prepared, :needs_input]),
        message: "a prepared or needs-input run records its snapshot digest"

      validate present(:problem_payload),
        where: attribute_equals(:preparation_status, :prepared),
        message: "a prepared run carries its problem"

      change filter(expr(preparation_status == :pending and is_nil(solve_status)))
    end

    update :start do
      description "Take the lease and mark the session that will solve."
      accept [:backend, :session_pid]
      require_atomic? false

      argument :lease_for, :integer do
        description "How long the lease lasts, in milliseconds."
        allow_nil? false
        default 300_000
        constraints min: 1
      end

      change filter(
               expr(
                 preparation_status == :prepared and is_nil(solve_status) and
                   is_nil(cancellation_reason)
               )
             )

      change {Changes.Lease, bump?: true}
    end

    update :renew_lease do
      description "Extend a live session's lease. Refused unless `epoch` still holds it."
      accept []
      require_atomic? false

      argument :epoch, :integer, allow_nil?: false

      argument :lease_for, :integer do
        allow_nil? false
        default 300_000
        constraints min: 1
      end

      change filter(expr(lease_epoch == ^arg(:epoch) and is_nil(solve_status)))
      change {Changes.Lease, bump?: false}
    end

    update :request_cancel do
      description "Record that a cancel was asked for. The session, or the sweep, ends the run."
      accept []
      require_atomic? false

      argument :reason, :atom do
        allow_nil? false
        default :requested
        constraints one_of: [:requested, :operator, :shutdown]
      end

      change filter(expr(is_nil(solve_status) and is_nil(cancellation_reason)))
      change set_attribute(:cancellation_reason, arg(:reason))
    end

    update :record_result do
      description """
      Record the solve outcome and release the lease. Refused unless `epoch` still holds the
      lease and the run has no outcome yet, so a late write cannot overwrite a terminal one.
      """

      accept [
        :solve_status,
        :complete?,
        :optimality,
        :outcome_reason,
        :result_payload,
        :stats,
        :backend
      ]

      require_atomic? false

      argument :epoch, :integer, allow_nil?: false

      validate present(:solve_status)
      validate Validations.ResultAxes

      change filter(expr(lease_epoch == ^arg(:epoch) and is_nil(solve_status)))
      change set_attribute(:lease_expires_at, nil)
      change set_attribute(:session_pid, nil)
    end
  end
end

defmodule AshEnterprise.Planning.Fragment.Run.Changes.Lease do
  @moduledoc false
  # Pure: the lease is a function of the clock and the row. `bump?: true` opens a new epoch.

  use Ash.Resource.Change

  @impl true
  def init(opts) do
    if is_boolean(Keyword.get(opts, :bump?)),
      do: {:ok, opts},
      else: {:error, "bump? must be a boolean"}
  end

  @impl true
  def change(changeset, opts, _context) do
    lease_for = Ash.Changeset.get_argument(changeset, :lease_for)
    expires_at = DateTime.add(DateTime.utc_now(), lease_for, :millisecond)
    changeset = Ash.Changeset.force_change_attribute(changeset, :lease_expires_at, expires_at)

    if opts[:bump?] do
      Ash.Changeset.force_change_attribute(
        changeset,
        :lease_epoch,
        changeset.data.lease_epoch + 1
      )
    else
      changeset
    end
  end
end

defmodule AshEnterprise.Planning.Fragment.Run.Validations.ResultAxes do
  @moduledoc false
  # Pure: the solve axes a result may combine (programme §1).

  use Ash.Resource.Validation

  @no_answer [:unknown, :invalid_model, :backend_failed, :cancelled]

  @impl true
  def validate(changeset, _opts, _context) do
    status = Ash.Changeset.get_attribute(changeset, :solve_status)
    complete? = Ash.Changeset.get_attribute(changeset, :complete?)
    optimality = Ash.Changeset.get_attribute(changeset, :optimality)

    # Checked in this order; the first refusal is the one reported.
    certificate_error(status, optimality) ||
      completeness_error(status, complete?) ||
      claim_error(status, optimality) ||
      :ok
  end

  defp certificate_error(status, optimality) do
    cond do
      status == :optimal and optimality != :optimal ->
        {:error, field: :optimality, message: "an optimal run carries an optimality certificate"}

      status != :optimal and optimality == :optimal ->
        {:error, field: :optimality, message: "only an optimal solve carries optimality :optimal"}

      true ->
        nil
    end
  end

  defp completeness_error(status, complete?) do
    cond do
      status in [:optimal, :infeasible] and complete? != true ->
        {:error,
         field: :complete?, message: "an #{status} outcome means the search ran to its end"}

      status in @no_answer and complete? != false ->
        {:error, field: :complete?, message: "a run with no answer did not finish its search"}

      true ->
        nil
    end
  end

  defp claim_error(status, optimality) do
    cond do
      status in @no_answer and optimality != :none ->
        {:error, field: :optimality, message: "a run with no answer has no optimality claim"}

      optimality == :bound and status != :feasible ->
        {:error, field: :optimality, message: "a bound only qualifies a feasible solve"}

      true ->
        nil
    end
  end
end
