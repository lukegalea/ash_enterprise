defmodule Battery.Operations.LookupSubmission do
  @moduledoc """
  `Submission.lookup_submission`: what the provider says about one submission, in the shape
  a `reconcile_with` lookup answers (`AshAgent.Invocation.Target.lookup/4`):

      %{"outcome" => "succeeded" | "unknown", "effect_ref" => id | nil,
        "effect_system" => "battery-registry"}

  It asks through `AshOperations.Reconcile.find/5`, which runs the declared
  `reconcile_with` read of `create_activation` (`list_activations`, filtered by the
  invocation's key) and never re-sends the call. One match is `succeeded`. None is
  `unknown`, because absence is not proof the provider never took the call; several are
  `unknown` with `reconcile_many`. Both are left to a person, never to `failed`.
  """

  use Ash.Resource.Actions.Implementation

  alias Battery.Operations.Registry

  @effect_system "battery-registry"

  @impl true
  def run(input, _opts, context) do
    key = input.arguments.invocation_key

    case AshOperations.Reconcile.find(
           Registry,
           :create_activation,
           %{client_reference: key},
           fn body -> Enum.filter(body["data"] || [], &(&1["clientReference"] == key)) end,
           Ash.Context.to_opts(context)
         ) do
      {:ok, activation} -> {:ok, answer("succeeded", activation["id"])}
      :none -> {:ok, answer("unknown", nil)}
      {:many, _activations} -> {:ok, answer("unknown", nil, "reconcile_many")}
      {:error, error} -> {:error, error}
    end
  end

  defp answer(outcome, effect_ref, code \\ nil) do
    %{"outcome" => outcome, "effect_ref" => effect_ref, "effect_system" => @effect_system}
    |> then(&if(code, do: Map.put(&1, "code", code), else: &1))
  end
end
