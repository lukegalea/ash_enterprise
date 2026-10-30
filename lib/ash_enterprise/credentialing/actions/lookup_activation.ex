defmodule AshEnterprise.Credentialing.Actions.LookupActivation do
  @moduledoc """
  `lookup_activation`: what the registry says about one credential's activation, as
  `%{"status" => "active" | "not_found" | "unknown", "reference" => reference | nil}`.

  The credential is read as the caller first, so the action answers only about a
  credential the caller may read.
  """

  use Ash.Resource.Actions.Implementation

  alias AshEnterprise.Credentialing
  alias AshEnterprise.Credentialing.Registry

  @impl true
  def run(input, _opts, context) do
    with {:ok, credential} <-
           Credentialing.get_credential(
             input.arguments.credential_id,
             Ash.Context.to_opts(context)
           ),
         {:ok, answer} <- Registry.lookup(credential.id) do
      {:ok, %{"status" => Atom.to_string(answer.status), "reference" => answer.reference}}
    end
  end
end
