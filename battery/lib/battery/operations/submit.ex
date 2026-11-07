defmodule Battery.Operations.Submit do
  @moduledoc """
  `Submission.submit`'s work: send the submission to the registry, then record the
  provider's id for it.

  The call is made before the update's transaction opens, so none is held while it is out,
  with the invocation's own context and the submission's id as `disclosure_ref`. Its
  `client_reference` is the invocation's key: the provider is asked to remember it, so
  `LookupSubmission` can ask the provider, by the same key, whether it took the call.

  A failure is added to the changeset as the typed `AshOperations.Error`, which the
  invocation classifies (`Battery.Operations.FailureClass`).
  """

  use Ash.Resource.Change

  alias Battery.Operations.Registry

  @impl true
  def change(changeset, _opts, context) do
    Ash.Changeset.before_transaction(changeset, &submit(&1, context))
  end

  defp submit(changeset, context) do
    key = changeset.context[:ash_agent][:invocation_key]

    arguments = %{client_reference: key, disclosure_ref: changeset.data.id}

    case Registry.create_activation(arguments, Ash.Context.to_opts(context)) do
      {:ok, %{"id" => activation_id}} when is_binary(activation_id) ->
        Ash.Changeset.force_change_attributes(changeset, %{
          client_reference: key,
          activation_id: activation_id
        })

      {:ok, _unrecognised} ->
        Ash.Changeset.add_error(
          changeset,
          AshOperations.Error.exception(
            reason: :bad_request,
            provider: :battery_registry,
            operation: :create_activation
          )
        )

      {:error, error} ->
        Ash.Changeset.add_error(changeset, error)
    end
  end
end
