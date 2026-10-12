defmodule AshEnterprise.Agents.Actions.ComposeToday do
  @moduledoc """
  `MorningBrief.compose_today`: open the actor's brief for a day and start the
  `morning.brief` process with it as subject. The process does the rest —
  composes the draft, opens the approval task on the owner, and records the
  decision (`priv/bpmn/morning_brief.bpmn`).

  Everything runs as the calling actor, under their policies: the brief is
  created with `start_for_date` (the owner is the actor, never an input) and
  the instance is started with the actor as `started_by`. The action is
  `transaction? true`, so a brief never exists without its process: if the
  start fails, the brief rolls back with it.

  ## Which definition

  `AshEnterprise.Process.Resolver.resolve/3` — the host's answer to "which
  `morning.brief` does this tenant run": its own bound copy if it has
  diverged, otherwise the platform baseline (`mix ash_enterprise.bpmn.publish`).
  The resolved definition is handed to `AshBpmn.start_instance/2` directly,
  and `AshEnterprise.Process.DefinitionLoader` finds it in the platform
  organization while the instance runs. A tenant therefore needs nothing
  provisioned to run the baseline. (The event-triggered lane cannot do this
  yet — see `AshEnterprise.Process` — which is why this is an explicit start
  and not a subscription.)

  ## Idempotent

  One brief per owner per day (`one_per_owner_per_day`). A day that already
  has the actor's brief is reported, not recomposed: the process has no path
  from its approval task back to its compose step, and a second process on
  the same subject would open a second approval task.
  """

  use Ash.Resource.Actions.Implementation

  require Ash.Query

  alias AshEnterprise.Agents.{MorningBrief, Today}
  alias AshEnterprise.Platform.LocalTime
  alias AshEnterprise.Process.Resolver

  @process "morning.brief"

  @impl true
  def run(input, _opts, context) do
    opts = Ash.Context.to_opts(context)
    date = input.arguments[:brief_date] || LocalTime.today()

    case existing(date, context.actor, opts) do
      {:ok, nil} -> compose(date, context, opts)
      {:ok, brief} -> {:ok, already(brief)}
      {:error, error} -> {:error, error}
    end
  end

  @doc "The actor's brief for `date`, or nil. Read as the actor."
  @spec existing(Date.t(), term(), keyword()) :: {:ok, struct() | nil} | {:error, term()}
  def existing(date, %{id: owner_id}, opts) do
    MorningBrief
    |> Ash.Query.for_read(:read, %{}, opts)
    |> Ash.Query.filter(owner_id == ^owner_id and brief_date == ^date)
    |> Ash.read_one(opts)
  end

  def existing(_date, _no_actor, _opts), do: {:ok, nil}

  defp compose(date, context, opts) do
    with {:ok, definition} <- definition(context.tenant),
         {:ok, brief} <- MorningBrief.start_for_date(date, opts),
         {:ok, _instance} <-
           AshBpmn.start_instance(AshEnterprise.Bpmn,
             definition: definition,
             subject: brief,
             actor: context.actor,
             tenant: context.tenant
           ) do
      {:ok,
       "Composing your morning brief for #{LocalTime.day(date)}. " <>
         "It will wait for your approval — say `today` to read it."}
    end
  end

  defp definition(nil), do: {:error, "a morning brief needs a tenant"}

  defp definition(tenant) do
    case Resolver.resolve(:process, @process, tenant) do
      {:ok, definition} ->
        {:ok, definition}

      {:error, reason} ->
        {:error,
         "no published #{@process} process for this tenant (#{inspect(reason)}) — " <>
           "run `mix ash_enterprise.bpmn.publish`"}
    end
  end

  defp already(brief) do
    "You already have a morning brief for #{LocalTime.day(brief.brief_date)} " <>
      "(#{Today.brief_status(brief.status)}) — there is one per day. Say `today` to read it."
  end
end
