defmodule AshEnterprise.Canonical.Projections.ZoneAdmission do
  @moduledoc """
  The real zone gate (ADR 0042): a landed record is admitted into the
  canonical store iff `AshEnterprise.Zones.admit/3` passes for the store's
  declared zone and the record's tags.

  ## The record's tags are its linked account's

  A record carries the `data_class` and `residency` of the
  `AshEnterprise.Integration.LinkedAccount` it was landed through
  (`source_metadata["linked_account_id"]`), set by the operator with
  `:tag_for_zone`. They are never guessed from content. An untagged account's
  records are refused (`:untagged_data_class` / `:untagged_residency`), and so
  is a record whose account is not among the projection's own
  (`:unknown_linked_account`).

  ## The store's zone

      config :ash_enterprise, AshEnterprise.Canonical.Projections.ZoneAdmission,
        zone: "my-zone"

  The id of a zone declared under `AshEnterprise.Zones`. With none configured,
  or one that is not declared, every record is refused (`:undeclared_zone`).
  The declaration is read per record, so narrowing it, letting it lapse
  (`:declaration_lapsed`) or withdrawing it takes effect on the next record.

  Pure apart from that read: the linked accounts come in the projection's
  context, so the gate never queries the database.
  """

  @behaviour AshEnterprise.Canonical.Projections.ZoneGate

  alias AshEnterprise.Zones
  alias AshEnterprise.Zones.Errors.Inadmissible

  @impl true
  def admit(source, context) do
    with {:ok, account} <- account(source, context) do
      tags = %{data_class: Map.get(account, :data_class), residency: Map.get(account, :residency)}

      case Zones.admit(zone(), tags) do
        :ok -> :ok
        {:error, %Inadmissible{reason: reason}} when is_atom(reason) -> {:deny, reason}
        {:error, _undeclared} -> {:deny, :undeclared_zone}
      end
    end
  end

  @doc "The configured zone id of the canonical store, or nil."
  @spec zone() :: String.t() | nil
  def zone do
    :ash_enterprise
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:zone)
  end

  defp account(%{source_metadata: %{"linked_account_id" => id}}, %{linked_accounts: accounts})
       when is_binary(id) and is_map(accounts) do
    with {:ok, uuid} <- Ecto.UUID.cast(id),
         {:ok, account} <- Map.fetch(accounts, uuid) do
      {:ok, account}
    else
      :error -> {:deny, :unknown_linked_account}
    end
  end

  defp account(_source, _context), do: {:deny, :unknown_linked_account}
end
