defmodule AshEnterprise.Platform.Lifecycle do
  @moduledoc """
  The CDM/Dataverse record lifecycle, expressed as a state machine.

  ## The two-column model, and why we keep only one

  Dataverse stores lifecycle in a *pair* of columns:

    * `statecode` — the coarse state. Active or Inactive.
    * `statuscode` — the fine-grained reason, and **each status belongs to
      exactly one state**.

  The correlation is published in the table reference and scraped into
  `priv/cdm/resolved/dataverse_*.json`, where a state carries `default_status`
  and a status carries the `state` it belongs to:

      state_code  0 -> {label: "Active",   default_status: 1}
      status_code 1 -> {label: "Active",   state: 0}

  Because `statuscode -> statecode` is a total function, storing both is storing
  the same fact twice, and two columns that must agree eventually disagree. So
  this platform stores **only the status**, as an atom, and derives `state_code`
  and `status_code` as calculations. Interop is preserved on read; the
  possibility of an inconsistent pair is removed at the source.

  ## Why a state machine rather than a plain enum

  An enum lets any value become any other. A record going from Active straight
  to some terminal status without passing through the intermediate step is a
  data-integrity bug that an enum cannot express and a state machine rejects.

  It also makes the lifecycle *visible*: `ash_state_machine` generates a Mermaid
  diagram of the transitions, which `clarity` renders alongside the ER and policy
  diagrams. A lifecycle written as scattered `set_attribute` calls is knowledge
  only the person who wrote it has.

  ## The canonical lifecycle

  Every entity scraped from the Dataverse reference that carries lifecycle option
  sets uses the same two-state shape, so it is the platform default. Entities
  with richer lifecycles — an opportunity that can be Won or Lost, an incident
  that can be Resolved or Cancelled — declare their own by implementing this
  behaviour.
  """

  @typedoc "A lifecycle status: the fine-grained value a record actually holds."
  @type status :: atom()

  @typedoc "A lifecycle state: the coarse Active/Inactive grouping."
  @type state :: atom()

  @doc "Every status a record may hold."
  @callback statuses() :: [status()]

  @doc "The status a newly created record starts in."
  @callback default_status() :: status()

  @doc "The coarse state a status belongs to."
  @callback state_for(status()) :: state()

  @doc "The Dataverse integer for a status, for interop."
  @callback status_code(status()) :: integer()

  @doc "The Dataverse integer for a state, for interop."
  @callback state_code(state()) :: integer()

  @doc "Legal transitions as `{action_name, from_statuses, to_status}`."
  @callback transitions() :: [{atom(), [status()], status()}]

  # --- the canonical implementation -------------------------------------------

  @statuses [:active, :inactive]

  # Straight from the scraped option sets. Do not renumber: these are the values
  # a real Dataverse instance uses, and they are what an import or export would
  # carry.
  @status_codes %{active: 1, inactive: 2}
  @state_codes %{active: 0, inactive: 1}
  @status_to_state %{active: :active, inactive: :inactive}

  @behaviour __MODULE__

  @impl true
  def statuses, do: @statuses

  @impl true
  def default_status, do: :active

  @impl true
  def state_for(status), do: Map.fetch!(@status_to_state, status)

  @impl true
  def status_code(status), do: Map.fetch!(@status_codes, status)

  @impl true
  def state_code(state), do: Map.fetch!(@state_codes, state)

  @impl true
  def transitions do
    [
      {:deactivate, [:active], :inactive},
      {:activate, [:inactive], :active}
    ]
  end

  @doc """
  The `status -> status_code` pairs, for building a derived calculation.
  """
  def status_code_pairs, do: Enum.map(@statuses, &{&1, status_code(&1)})

  @doc """
  The `status -> state_code` pairs, for building a derived calculation.

  This is the composition `status -> state -> state_code`, which is exactly the
  correlation the Dataverse docs publish and the reason `state_code` need not be
  stored.
  """
  def state_code_pairs, do: Enum.map(@statuses, &{&1, &1 |> state_for() |> state_code()})
end
