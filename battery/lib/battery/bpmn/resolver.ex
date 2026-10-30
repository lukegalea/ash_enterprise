defmodule Battery.Bpmn.Resolver do
  @moduledoc """
  The battery's `AshBpmn.AssignmentResolver`.

  The battery's processes have no human tasks; its governed invocations' approvals do
  (`Battery.Execution.RequestApproval`). Two clauses are answered, from the battery's
  own members: a `role` candidate clause names every `Battery.Execution.Member` holding
  that role (an `approver_role` atom matches the role of the same name), and an
  exclusion `"subject.<field>"` names the person in that field of the subject. Anything
  else contributes nobody.
  """

  require Ash.Query

  alias Battery.Execution.Member

  def candidates(specs, _ctx), do: {:ok, Enum.flat_map(specs, &candidate/1)}

  def exclusions(specs, ctx), do: {:ok, specs |> Enum.flat_map(&excluded(&1, ctx))}

  defp candidate(%{"kind" => "role", "of" => role}) when is_binary(role) do
    Member
    |> Ash.Query.filter(role == ^role)
    |> Ash.read!(authorize?: false)
    |> Enum.map(&%{type: :user, id: &1.id})
  end

  defp candidate(_spec), do: []

  defp excluded(%{"who" => "subject." <> field}, %{subject: subject}) when is_map(subject) do
    case Map.get(subject, String.to_existing_atom(field)) do
      nil -> []
      id -> [id]
    end
  end

  defp excluded(_spec, _ctx), do: []
end
