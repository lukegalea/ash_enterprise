defmodule Battery.Operations.FollowUp do
  @moduledoc """
  The follow-up to a webhook nudge: for each `:received` delivery, read the provider by the
  activation id the delivery holds (`Registry.get_activation`), emit an
  `ActivationSettled` built from THE READ, and mark the delivery followed up.

  It runs synchronously, because the battery has no Oban of its own; a host would enqueue
  it. The webhook's own payload never reaches an envelope: only the id was kept.
  """

  require Ash.Query

  alias Battery.Operations.{ActivationSettled, Delivery, Registry}

  @doc "Follow up every received delivery. Returns the number followed up."
  @spec drain() :: non_neg_integer()
  def drain do
    Delivery
    |> Ash.Query.filter(status == :received)
    |> Ash.Query.sort(inserted_at: :asc)
    |> Ash.read!()
    |> Enum.count(&follow_up/1)
  end

  defp follow_up(delivery) do
    case Registry.get_activation(%{activation_id: delivery.activation_id}) do
      {:ok, activation} ->
        ActivationSettled
        |> Ash.Changeset.for_create(:emit, ActivationSettled.envelope(delivery, activation))
        |> Ash.create!()

        delivery |> Ash.Changeset.for_update(:followed_up, %{}) |> Ash.update!()
        true

      {:error, _error} ->
        false
    end
  end
end
