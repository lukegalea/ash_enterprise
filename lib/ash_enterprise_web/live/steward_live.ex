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

  def handle_event("escalate", %{"id" => id}, socket) do
    decide(socket, id, :escalate)
  end

  defp decide(socket, id, action) do
    actor = socket.assigns.current_user
    tenant = ActorContext.tenant(actor)

    with {:ok, candidate} <- fetch(id, tenant, actor),
         {:ok, _updated} <-
           candidate
           |> Ash.Changeset.for_update(action, %{}, tenant: tenant, actor: actor)
           |> Ash.update(tenant: tenant, actor: actor) do
      {:noreply, socket |> put_flash(:info, escalate_flash(action)) |> refresh()}
    else
      {:error, error} ->
        {:noreply, put_flash(socket, :error, "Could not #{action} the match: #{message(error)}")}
    end
  end

  defp escalate_flash(:escalate),
    do: "Marked unsure — the candidate stays open for a senior steward."

  defp escalate_flash(action), do: "Match #{action}ed."

  defp refresh(socket) do
    actor = socket.assigns[:current_user]
    tenant = actor && ActorContext.tenant(actor)

    {:ok, %{items: items}} =
      ReviewQueue.pending(kinds: [:mdm_match], actor: actor, tenant: tenant, limit: 50)

    # The diff rows are built HERE — actor and tenant are known — so
    # render stays pure. Two reads total, not two per item per render.
    diffs = Map.new(items, fn item -> {item.id, diff(item, tenant)} end)

    socket
    |> assign(:items, items)
    |> assign(:empty?, items == [])
    |> assign(:diffs, diffs)
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
          <div class="flex items-center justify-between gap-2">
            <h1 class="text-2xl font-semibold">Steward queue</h1>
            <div class="flex items-center gap-2">
              <.link navigate={~p"/app/processes"} class="btn btn-ghost btn-sm">
                <.icon name="hero-queue-list" class="size-4" /> Process model
              </.link>
              <.link navigate={~p"/app/mdm/import"} class="btn btn-outline btn-sm">
                <.icon name="hero-arrow-up-tray" class="size-4" /> Import CSV
              </.link>
            </div>
          </div>
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
                <span class="font-medium">Possible duplicate person</span>
                <span class="badge badge-warning badge-sm">review · score {Decimal.round(
                  item.record.score,
                  2
                )}</span>
              </div>
              <table class="table table-sm text-sm">
                <thead>
                  <tr>
                    <th>Field</th><th>Staged</th><th>Golden</th><th>Survivorship</th>
                  </tr>
                </thead>
                <tbody>
                  <%= for {field, staged_value, golden_value, winner} <- Map.get(@diffs, item.id, []) do %>
                    <tr class={winner == :staged && "bg-warning/10"}>
                      <td class="capitalize">{field}</td>
                      <td class={winner == :staged && "font-semibold"}>{staged_value || "—"}</td>
                      <td class={winner == :golden && "font-semibold"}>{golden_value || "—"}</td>
                      <td class="text-xs opacity-60">{winner}</td>
                    </tr>
                  <% end %>
                </tbody>
              </table>
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
                  Reject — keep as a separate person
                </button>
                <button
                  id={"escalate-#{item.id}"}
                  class="btn btn-ghost btn-sm"
                  phx-click="escalate"
                  phx-value-id={item.id}
                >
                  <.icon name="hero-arrow-up-circle" class="size-4" /> Unsure — keep open
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

  # The side-by-side the plan asks for: staged value vs golden value per
  # mapped field, survivorship winner highlighted (the golden's own values
  # always beat a fold — ties go to the golden).
  defp diff(item, tenant) do
    with {:ok, staged} <-
           Ash.get(AshEnterprise.Mdm.StagedRecord, item.record.staged_record_id,
             tenant: tenant,
             authorize?: false
           ),
         {:ok, golden} <-
           Ash.get(AshEnterprise.Canonical.Person, item.record.golden_id,
             tenant: tenant,
             authorize?: false
           ) do
      mapped = staged.mapped || %{}

      for field <- ~w(name email) do
        staged_value = mapped[field]
        golden_value = golden_value(golden, field)

        winner =
          cond do
            is_nil(golden_value) and not is_nil(staged_value) -> :staged
            true -> :golden
          end

        {field, staged_value, golden_value, winner}
      end
    else
      _ -> []
    end
  end

  defp golden_value(golden, "email"), do: golden.email && to_string(golden.email)
  defp golden_value(golden, "name"), do: golden.name && to_string(golden.name)
  defp golden_value(_golden, _field), do: nil

  defp explanation_rules(%{"rules" => rules}) when is_list(rules) do
    Enum.map(rules, fn
      %{"rule" => name, "score" => score} -> "#{name}: #{score}"
      rule when is_binary(rule) -> rule
      rule -> inspect(rule)
    end)
  end

  defp explanation_rules(_), do: nil
end
