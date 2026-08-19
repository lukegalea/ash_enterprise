defmodule AshEnterprise.Process.Trigger.ResourceName do
  @moduledoc """
  Resolving the resource name a trigger matches on, in the form the audit log actually records.

  There are three spellings of the same thing in play, and picking the wrong one produces a
  trigger that compares unequal to every event forever — the same silent-never-fires failure
  the validations in this file exist to prevent, arriving through the back door. It was in fact
  written that way first, and the test that provokes a real audited write is what caught it.

  | Where | Form |
  |---|---|
  | The `audit_events` column | `"Elixir.AshEnterprise.Security.Role"` — `AshEvents` stores the module and Postgres holds its `to_string/1` |
  | `event.resource` as Ash returns it | the **module atom** `AshEnterprise.Security.Role`, cast back on read |
  | Here, and in the event context a guard sees | `"AshEnterprise.Security.Role"` |

  The third is chosen deliberately. It is what a person types, what a properties panel shows,
  and what a FEEL guard compares against — `event.resource = "AshEnterprise.Security.Role"`
  reads like the thing it means, where the prefixed form reads like an implementation detail
  leaking into a business rule.

  So a name is accepted in either form, normalised to the short one on write, and compared in
  `AshEnterprise.Process.Triggers.Dispatch` against `inspect(event.resource)`.
  """

  @prefix "Elixir."

  @doc "Resolves a name in either form to its module, without creating an atom."
  @spec resolve(term()) :: {:ok, module()} | :error
  def resolve(name) when is_binary(name) do
    module =
      if String.starts_with?(name, @prefix) do
        String.to_existing_atom(name)
      else
        String.to_existing_atom(@prefix <> name)
      end

    if Code.ensure_loaded?(module) and function_exported?(module, :spark_dsl_config, 0) do
      {:ok, module}
    else
      :error
    end
  rescue
    # Nothing has ever compiled a module by that name: a typo, and one that would otherwise
    # present as a trigger that quietly never matches.
    ArgumentError -> :error
  end

  def resolve(_name), do: :error

  @doc "The canonical stored form: the short name, as a person writes it."
  @spec canonical(module()) :: String.t()
  def canonical(module), do: inspect(module)

  @doc """
  The short name of the resource an event names.

  `event.resource` is a module atom, not a string — Ash casts the column back on read. Every
  comparison against a stored `match_resource` goes through this.
  """
  @spec of_event(module() | String.t()) :: String.t()
  def of_event(resource) when is_atom(resource), do: inspect(resource)
  def of_event(resource) when is_binary(resource), do: short(resource)

  @doc "A name with the `Elixir.` prefix stripped, for comparing against a source-style prefix."
  @spec short(String.t()) :: String.t()
  def short(name) when is_binary(name), do: String.replace_prefix(name, @prefix, "")
  def short(name), do: to_string(name)
end

defmodule AshEnterprise.Process.Trigger.Validations.HasATarget do
  @moduledoc """
  A trigger must name either a process to start or a decision that chooses one.

  Neither is not a disabled trigger — it is a trigger that matches events and then has nothing
  to do with them, which shows up as a growing pile of `:failed` dispatch rows rather than as a
  configuration error.
  """

  use Ash.Resource.Validation

  @impl true
  def validate(changeset, _opts, _context) do
    process = Ash.Changeset.get_attribute(changeset, :process_key)
    decision = Ash.Changeset.get_attribute(changeset, :decision_key)

    if blank?(process) and blank?(decision) do
      {:error,
       field: :process_key, message: "a trigger needs either a process_key or a decision_key"}
    else
      :ok
    end
  end

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_), do: false
end

defmodule AshEnterprise.Process.Trigger.Validations.NotSelfTriggering do
  @moduledoc """
  Refuses a trigger that matches a resource in the process or decision domains.

  Those domains audit the writes that matter — a definition published, a task decided — so a
  process started by a trigger produces audit events of its own. A trigger matching one of them
  would feed itself, and the unbounded version is the kind of thing that is discovered in
  production rather than in a test.

  This closes the direct path. `AshEnterprise.Process.TriggerDispatch`'s `depth` bounds an
  indirect one, so a cycle through some future path is bounded rather than merely improbable.

  Matched by module prefix rather than by an enumerated list, so a resource added to either
  domain later is covered without anyone remembering to come back here.
  """

  use Ash.Resource.Validation

  @refused_prefixes ["AshEnterprise.Bpmn.", "AshEnterprise.Decisions.", "AshEnterprise.Process."]

  @impl true
  def validate(changeset, _opts, _context) do
    resource =
      changeset
      |> Ash.Changeset.get_attribute(:match_resource)
      |> Kernel.||("")
      |> AshEnterprise.Process.Trigger.ResourceName.short()

    if Enum.any?(@refused_prefixes, &String.starts_with?(resource, &1)) do
      {:error,
       field: :match_resource,
       message:
         "a trigger may not match #{resource}: the process and decision domains audit their " <>
           "own writes, so a trigger on one would start processes that feed it"}
    else
      :ok
    end
  end
end

defmodule AshEnterprise.Process.Trigger.Validations.MatchesAnAuditedResource do
  @moduledoc """
  Refuses a trigger whose resource does not exist, or exists and is not audited.

  ## The audit log is not a change feed

  It is a feed of **writes that went through an Ash action**, which is a narrower and less
  obvious thing. `ash_events` appends by *wrapping actions* — `create_action_wrapper` and its
  siblings — not by observing changes. So anything that changes a row without running an Ash
  action produces no event, and a trigger watching for it waits forever.

  The case that will actually bite is the strangler. `AshEnterprise.Legacy.User` reads a
  Postgres view over `legacy.users`, and the writes worth reacting to are the *old
  application's* — raw SQL, no Ash action. `AshStrangler.Listener` does synthesize an
  `Ash.Notifier.Notification` for them, which is what makes the LiveView update live, but a
  notification is not an event: measured, an audited resource carries **no notifiers at all**
  (`Ash.Resource.Info.notifiers(AshEnterprise.Security.Role) == []`), because `ash_events`
  registers none. There is no configuration that connects the two.

  So "a user appears in the legacy system, start onboarding" — one of the first processes
  anyone will try to model on a strangler-migrated application — would **silently never fire**.
  Nothing errors; the cursor advances past events that were never written.

  That is the same failure shape as a trigger feeding itself, in the opposite direction, and it
  gets the same treatment: refused when it is declared, with the reason named, rather than
  discovered by drawing a diagram against it.

  ## What it also catches

  A misspelled module name. `match_resource` is a string compared against
  `AshEnterprise.Audit.EventLog.resource`, so a typo matches nothing and is indistinguishable
  from a trigger that is simply never relevant.

  ## If you need it anyway

  Two honest routes, neither built speculatively: subscribe the trigger index to the
  strangler's PubSub topics — at-most-once, so only for latency-tolerant triggers, and that
  weaker guarantee must be *declared* rather than inherited — or have the listener perform a
  real Ash action so the write is audited like any other, which trades away the read-only
  property of the `:read_from_legacy` phase.
  """

  use Ash.Resource.Validation

  @impl true
  def validate(changeset, _opts, _context) do
    name = Ash.Changeset.get_attribute(changeset, :match_resource)

    case AshEnterprise.Process.Trigger.ResourceName.resolve(name) do
      {:ok, module} -> audited(module, name)
      :error -> {:error, not_a_resource(name)}
    end
  end

  defp audited(module, name) do
    if AshEvents.Events in Ash.Resource.Info.extensions(module) do
      :ok
    else
      {:error,
       field: :match_resource,
       message:
         "#{name} is not audited, so it writes no events and this trigger would never fire. " <>
           "The audit log is a feed of writes that went through an Ash action, not of every " <>
           "change to a row -- see AshEnterprise.Process.Trigger.Validations." <>
           "MatchesAnAuditedResource"}
    end
  end

  defp not_a_resource(name) do
    [
      field: :match_resource,
      message:
        "#{name} is not a loadable Ash resource. A trigger matches on the resource name the " <>
          "audit log records, so a name nothing writes under would never fire"
    ]
  end
end

defmodule AshEnterprise.Process.Trigger.Changes.AssignVersion do
  @moduledoc """
  Numbers a new trigger `max(version) + 1` for its key, within the tenant.

  Read through the changeset's own tenant, so two tenants' version sequences are independent —
  the same arrangement `AshBpmn.Resources.Definition` uses, and for the same reason: a version
  number that means different things to different tenants is worse than no version number.

  A read that fails is **not** treated as "there are no versions yet". Swallowing it would
  number the row 1 and then report a duplicate-key error for what was actually a policy
  problem.
  """

  use Ash.Resource.Change

  require Ash.Query

  @impl true
  def change(changeset, _opts, context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      key = Ash.Changeset.get_attribute(changeset, :key)

      highest =
        AshEnterprise.Process.Trigger
        |> Ash.Query.for_read(:read, %{}, Ash.Context.to_opts(context))
        |> Ash.Query.filter(key == ^key)
        |> Ash.Query.sort(version: :desc)
        |> Ash.Query.limit(1)
        |> Ash.read!(Ash.Context.to_opts(context))

      next =
        case highest do
          [%{version: version}] -> version + 1
          [] -> 1
        end

      Ash.Changeset.force_change_attribute(changeset, :version, next)
    end)
  end
end

defmodule AshEnterprise.Process.Trigger.Changes.NormalizeMatchResource do
  @moduledoc """
  Stores `match_resource` in the form the audit log records it.

  See `AshEnterprise.Process.Trigger.ResourceName`. Accepting a name in either form and storing
  one is what keeps `Dispatch.matches?/2` a plain string comparison rather than a place where
  two spellings have to be reconciled at dispatch time, once per event, forever.
  """

  use Ash.Resource.Change

  alias AshEnterprise.Process.Trigger.ResourceName

  @impl true
  def change(changeset, _opts, _context) do
    case ResourceName.resolve(Ash.Changeset.get_attribute(changeset, :match_resource)) do
      {:ok, module} ->
        Ash.Changeset.force_change_attribute(
          changeset,
          :match_resource,
          ResourceName.canonical(module)
        )

      # Left alone: `MatchesAnAuditedResource` reports it, and reporting it twice would
      # produce two errors for one mistake.
      :error ->
        changeset
    end
  end
end

defmodule AshEnterprise.Process.Trigger.Changes.EnsureCursor do
  @moduledoc """
  Creates the tenant's dispatch cursor when a trigger is published, if it has none.

  A trigger fires on what happens after it exists, so the cursor starts at the newest event
  rather than at zero. Doing it here rather than leaving it to the first sweep closes the
  window between publishing and that sweep — see
  `AshEnterprise.Process.Triggers.SweepWorker.ensure_cursor/1` for why starting at zero would
  be worse than a gap.
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn changeset, trigger ->
      AshEnterprise.Process.Triggers.SweepWorker.ensure_cursor(changeset.tenant)
      {:ok, trigger}
    end)
  end
end
