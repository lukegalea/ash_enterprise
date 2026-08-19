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
    resource = Ash.Changeset.get_attribute(changeset, :match_resource) || ""

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
