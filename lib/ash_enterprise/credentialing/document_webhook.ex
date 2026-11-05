defmodule AshEnterprise.Credentialing.DocumentWebhook do
  @moduledoc """
  What the filing system's "document received" webhook does here: record the delivery
  (`AshEnterprise.Credentialing.DocumentEvent`, action `receive`) and answer how it was
  taken.

  A webhook is at-least-once and unordered, so this is idempotent on the sender's delivery
  id: the second delivery of the same message is `:duplicate`, never a second row and never
  a second wake of the case waiting for it. A delivery for a case that is not waiting yet is
  recorded all the same; the case finds it when it starts to wait (the receive task's
  lookback).
  """

  require Ash.Query

  alias AshEnterprise.Credentialing
  alias AshEnterprise.Credentialing.DocumentEvent
  alias AshEnterprise.Platform.SystemActor

  @source "urn:clinic:filing-system"

  @doc "The `source` of every delivery this handler records."
  @spec source() :: String.t()
  def source, do: @source

  @doc """
  Records delivery `delivery_id`: a document of `kind` for the credential `credential_id`.
  `:received` the first time, `:duplicate` after.
  """
  @spec deliver(Ash.UUID.t(), Ash.UUID.t(), String.t(), String.t()) ::
          :received | :duplicate | {:error, term()}
  def deliver(tenant, credential_id, delivery_id, kind \\ "certificate") do
    opts = [actor: SystemActor.oban(), tenant: tenant]

    attrs = %{
      event_id: delivery_id,
      source: @source,
      subject: credential_id,
      time: DateTime.utc_now(),
      data: %{"kind" => kind}
    }

    case Credentialing.receive_document(attrs, opts) do
      {:ok, _row} -> :received
      {:error, error} -> if delivered?(delivery_id, tenant), do: :duplicate, else: {:error, error}
    end
  end

  defp delivered?(delivery_id, tenant) do
    DocumentEvent
    |> Ash.Query.filter(source == ^@source and event_id == ^delivery_id)
    |> Ash.exists?(authorize?: false, tenant: tenant)
  end
end
