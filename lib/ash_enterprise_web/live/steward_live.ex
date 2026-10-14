defmodule AshEnterpriseWeb.StewardLive do
  @moduledoc """
  The steward's queue at `/app/steward`: the review-banded match candidates
  that await a person's confirm or reject (ADR 0050, MDM-4).

  The queue is `AshEnterprise.SystemOne.ReviewQueue` filtered to `:mdm_match`
  — the same ordered, oldest-first read the dashboard count uses — and the
  acts are the candidate's own person-gated `:confirm`/`:reject` actions, so
  the surface adds no second security model: what a steward may act on is
  what the platform's grant union lets them read and update.
  """

  use AshEnterpriseWeb, :live_view

  alias AshEnterprise.Mdm.MatchCandidate
  alias AshEnterprise.Security.ActorContext
  alias AshEnterprise.SystemOne.ReviewQueue

  require Ash.Query

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, "Steward queue")
      |> refresh()

    {:ok, socket}
  end

  @impl true
  def handle_event("confirm", %{"id" => id}, socket) do
    decide(socket, id, :confirm)
  end

  def handle_event("reject", %{"id" => id}, socket) do
    decide(socket, id, :reject)
  end

  defp decide(socket, id, action) do
    actor = socket.assigns.current_user
    tenant = ActorContext.tenant(actor)

    with {:ok, candidate} <- fetch(id, tenant, actor),
         {:ok, _updated} <-
           candidate
           |> Ash.Changeset.for_update(action, %{}, tenant: tenant, actor: actor)
           |> Ash.update(tenant: tenant, actor: actor) do
      {:noreply, socket |> put_flash(:info, "Match #{action}ed.") |> refresh()}
    else
      {:error, error} ->
        {:noreply, put_flash(socket, :error, "Could not #{action} the match: #{message(error)}")}
    end
  end

  defp refresh(socket) do
    actor = socket.assigns[:current_user]
    tenant = actor && ActorContext.tenant(actor)

    {:ok, %{items: items}} =
      ReviewQueue.pending(kinds: [:mdm_match], actor: actor, tenant: tenant, limit: 50)

    socket
    |> assign(:items, items)
    |> assign(:empty?, items == [])
  end

  defp fetch(id, tenant, actor) do
    MatchCandidate
    |> Ash.Query.filter(id == ^id and band == ^:review and status == ^:pending)
    |> Ash.read_one(tenant: tenant, actor: actor)
  end

  defp message(%Ash.Error.Forbidden{}), do: "you are not permitted to act on this candidate"
  defp message(error), do: Exception.message(error)

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={assigns[:current_scope]} width="max-w-5xl">
      <div class="space-y-4">
        <header class="space-y-1">
          <h1 class="text-2xl font-semibold">Steward queue</h1>
          <p class="text-sm opacity-70">
            Review-banded matches awaiting a person's decision. Confirming merges the
            staged record into the golden record; rejecting leaves it a record of its own.
          </p>
        </header>

        <div class={[
          "rounded-box border border-base-300 bg-base-100 divide-y divide-base-200",
          @empty? && "hidden"
        ]}>
          <%= for item <- @items do %>
            <div id={"candidate-#{item.id}"} class="p-4 space-y-2">
              <div class="flex flex-wrap items-baseline justify-between gap-2">
                <span class="font-medium">{item.record.golden_resource}</span>
                <span class="badge badge-warning badge-sm">review · score {Decimal.to_string(
                  item.record.score
                )}</span>
              </div>
              <p class="text-sm opacity-70 break-all">
                staged {item.record.staged_record_id} → golden {item.record.golden_id}
              </p>
              <%= if rules = explanation_rules(item.record.explanation) do %>
                <ul class="text-xs opacity-70 list-disc list-inside">
                  <%= for rule <- rules do %>
                    <li>{rule}</li>
                  <% end %>
                </ul>
              <% end %>
              <div class="flex gap-2 pt-1">
                <button
                  id={"confirm-#{item.id}"}
                  class="btn btn-primary btn-sm"
                  phx-click="confirm"
                  phx-value-id={item.id}
                >
                  Confirm match
                </button>
                <button
                  id={"reject-#{item.id}"}
                  class="btn btn-ghost btn-sm"
                  phx-click="reject"
                  phx-value-id={item.id}
                >
                  Reject
                </button>
              </div>
            </div>
          <% end %>
        </div>

        <div
          :if={@empty?}
          class="rounded-box border border-base-300 bg-base-100 p-8 text-center opacity-60"
        >
          The queue is empty — no review-banded matches are waiting.
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp explanation_rules(%{"rules" => rules}) when is_list(rules) do
    Enum.map(rules, fn
      %{"rule" => name, "score" => score} -> "#{name}: #{score}"
      rule when is_binary(rule) -> rule
      rule -> inspect(rule)
    end)
  end

  defp explanation_rules(_), do: nil
end
