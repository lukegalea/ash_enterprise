defmodule AshEnterprise.Execution.Actions.ExportAttestation do
  @moduledoc """
  `export_attestation`: the manifest as an in-toto Statement v1
  (`AshEnterprise.Execution.Release.Attestation`). A draft has nothing to attest and is
  refused.
  """

  use Ash.Resource.Actions.Implementation

  alias AshEnterprise.Execution.Release.Attestation

  @impl true
  def run(input, _opts, context) do
    case Ash.get(input.resource, input.arguments.record_id, Ash.Context.to_opts(context)) do
      {:ok, %{status: :draft}} ->
        {:error,
         Ash.Error.Changes.InvalidArgument.exception(
           field: :record_id,
           message: "a draft has not been resolved, so there is nothing to attest"
         )}

      {:ok, manifest} ->
        {:ok, Attestation.statement(manifest)}

      {:error, error} ->
        {:error, error}
    end
  end
end
