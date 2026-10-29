defmodule Battery.Compliance.Activation do
  @moduledoc """
  The service tasks of the scheduled-activation process, behind the
  battery's `AshBpmn.ActionInvoker`:

    * `activate_scheduled_revision` — activates the subject's approved
      ash_compliance `RuleSetRevision` with `effective_at` set to the
      subject's instant (future-dated or backdated; the revision's own
      succession retires its predecessor at the same instant);
    * `reevaluate_scope` — re-answers every applicant in the subject's
      organization as of now, recording one ash_decisions evaluation each.

  A redelivered activation finds the revision already in force at the
  instant and does nothing, so the node is safe to run twice.
  """

  require Ash.Query

  alias AshCompliance.Resources.RuleSetRevision
  alias Battery.Compliance.{ScheduledActivation, Standing}

  @doc "The `activate_scheduled_revision` service task."
  def activate_from_process(ctx), do: activate(ctx[:subject])

  @doc "The `reevaluate_scope` service task."
  def reevaluate_from_process(ctx) do
    %ScheduledActivation{organization_id: organization_id} = ctx[:subject]

    case Standing.reevaluate_scope(organization_id, DateTime.utc_now()) do
      {:ok, _answers} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Activates the requested revision effective at the request's instant."
  def activate(%ScheduledActivation{} = request) do
    case revision(request) do
      nil ->
        {:error, {:no_such_revision, request.rule_set_name, request.revision}}

      revision ->
        if in_force_at?(revision, request.effective_at) do
          :ok
        else
          revision
          |> AshCompliance.Domain.activate_rule_set_revision(
            %{effective_at: request.effective_at},
            authorize?: false
          )
          |> case do
            {:ok, _activated} -> :ok
            {:error, reason} -> {:error, reason}
          end
        end
    end
  end

  defp revision(request) do
    RuleSetRevision
    |> Ash.Query.filter(
      organization_id == ^request.organization_id and name == ^request.rule_set_name and
        revision == ^request.revision
    )
    |> Ash.read_one!(authorize?: false)
  end

  defp in_force_at?(revision, instant) do
    RuleSetRevision
    |> Ash.Query.filter(id == ^revision.id and status == :active)
    |> Ash.Query.as_of(instant)
    |> Ash.exists?(authorize?: false)
  end
end
