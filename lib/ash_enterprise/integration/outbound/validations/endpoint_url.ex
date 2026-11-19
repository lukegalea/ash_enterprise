defmodule AshEnterprise.Integration.Outbound.Validations.EndpointUrl do
  @moduledoc """
  An endpoint URL passes the egress guard's static checks
  (`AshEnterprise.Integration.Outbound.Egress.check_url/1`): `https`, port 443, no user
  information, and not a non-public IP literal. Every send checks the resolved addresses
  again.
  """

  use Ash.Resource.Validation

  alias AshEnterprise.Integration.Outbound.Egress

  @impl true
  def init(opts), do: {:ok, opts}

  @impl true
  def validate(changeset, _opts, _context) do
    case Ash.Changeset.get_attribute(changeset, :url) do
      nil ->
        :ok

      url ->
        case Egress.check_url(url) do
          {:ok, _uri} ->
            :ok

          {:error, code} ->
            {:error,
             field: :url, message: "is not an allowed destination (%{code})", vars: [code: code]}
        end
    end
  end
end
