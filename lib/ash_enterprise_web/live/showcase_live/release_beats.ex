defmodule AshEnterpriseWeb.ShowcaseLive.ReleaseBeats do
  @moduledoc """
  The release beats of the tour (`AshEnterpriseWeb.ShowcaseLive.Credentialing`, beats 16 to
  19, showcase slice 4): the licence reader's candidate release measured and refused by its
  injection case, a routing table that changes under a running case, a shadow rerun, and a
  deploy that changes what an approval was bound to.

  The page owns the events and the data (`AshEnterprise.Showcase.Release.read/2`); this
  renders them. A beat that needs a fault control says in place that it runs in the demo
  build when the fault panel is off (`AshEnterpriseWeb.ShowcaseLive.CaseBeats.demo_build_note/1`).
  Copy is in English and French through the `showcase` Gettext domain.
  """

  use AshEnterpriseWeb, :html

  alias AshEnterpriseWeb.ShowcaseLive.CaseBeats

  attr :release, :map, required: true
  attr :credentials, :list, required: true
  attr :activations, :list, required: true
  attr :cases, :list, required: true
  attr :fault_controls?, :boolean, required: true

  def beats(assigns) do
    ~H"""
    <li id="beat-candidate">
      <.card>
        <h2 class="font-heading text-lg">
          {dgettext("showcase", "16. A candidate release fails its injection case (F9)")}
        </h2>
        <p class="text-sm">
          {dgettext(
            "showcase",
            "As ines@example.com, the clinic director, measure the licence reader's candidate: a prompt that tells it to carry out the notes a filing clerk leaves in a document. The suite runs without effect, then ask for the release."
          )}
        </p>
        <p class="text-sm text-foreground/70">
          {dgettext(
            "showcase",
            "Look for: the ordinary case passes and the injection case fails, in a lane of its own, and the release is refused with the reason shown. Nobody is asked to approve it."
          )}
        </p>
        <div class="flex flex-wrap gap-3">
          <.button id="measure-candidate" phx-click="measure" size="sm">
            {dgettext("showcase", "Measure the candidate")}
          </.button>
          <.button
            :if={@release.candidate && @release.candidate.lanes}
            id="request-release"
            phx-click="request_release"
            size="sm"
          >
            {dgettext("showcase", "Ask to release it")}
          </.button>
        </div>
        <.candidate candidate={@release.candidate} />
      </.card>
    </li>

    <li id="beat-routing">
      <.card>
        <h2 class="font-heading text-lg">
          {dgettext("showcase", "17. The routing table changes under a running case (F10)")}
        </h2>
        <p class="text-sm">
          {dgettext(
            "showcase",
            "Open a case (beat 10), change the routing table, open another, then route both. A case routes by the table version of the release it started under."
          )}
        </p>
        <p class="text-sm text-foreground/70">
          {dgettext(
            "showcase",
            "Look for: the older case keeps version 1 and the committee as its route, the newer one is on version 2 and the director. Rolling a release back writes the earlier versions again."
          )}
        </p>
        <CaseBeats.demo_build_note fault_controls?={@fault_controls?} />
        <div :if={@fault_controls?}>
          <.button id="fault-routing" phx-click="fault" phx-value-control="routing" size="sm">
            {dgettext("showcase", "Change the routing table")}
          </.button>
        </div>
        <p id="routing-table" data-version={@release.routing.table_version}>
          <%= if @release.routing.table_version do %>
            {dgettext("showcase", "The table is on version %{version} now.",
              version: @release.routing.table_version
            )}
          <% else %>
            {dgettext("showcase", "No release pins the table yet.")}
          <% end %>
        </p>
        <p :if={@release.routing.cases == []} id="routed-none" class="text-sm text-foreground/60">
          {dgettext("showcase", "None yet.")}
        </p>
        <ul :if={@release.routing.cases != []} id="routed-rows" class="space-y-2 text-sm">
          <li
            :for={row <- @release.routing.cases}
            id={"routed-#{row.id}"}
            data-table-version={row.table_version}
            class="flex flex-wrap items-center gap-3"
          >
            <span>{row.number}</span>
            <span :if={row.table_version}>
              {dgettext("showcase", "started under table version %{version}",
                version: row.table_version
              )}
            </span>
            <span :if={is_nil(row.table_version)}>
              {dgettext("showcase", "started under no release")}
            </span>
            <.button id={"route-#{row.id}"} phx-click="route" phx-value-id={row.id} size="sm">
              {dgettext("showcase", "Route it")}
            </.button>
          </li>
        </ul>
      </.card>
    </li>

    <li id="beat-shadow">
      <.card>
        <h2 class="font-heading text-lg">
          {dgettext("showcase", "18. A shadow rerun activates nobody (F12)")}
        </h2>
        <p class="text-sm">
          {dgettext(
            "showcase",
            "As the clinic director, rerun the same suite in shadow mode, the way a candidate is compared beside live work."
          )}
        </p>
        <p class="text-sm text-foreground/70">
          {dgettext(
            "showcase",
            "Look for: every tool call, the one the injected note asks for too, was answered from the case's fixtures and marked simulated. No activation was asked for and the number of active credentials did not move."
          )}
        </p>
        <div>
          <.button id="run-shadow" phx-click="shadow" size="sm">
            {dgettext("showcase", "Rerun in shadow")}
          </.button>
        </div>
        <p id="active-credentials" data-active={active(@credentials)}>
          {dngettext(
            "showcase",
            "%{count} credential is active now.",
            "%{count} credentials are active now.",
            active(@credentials)
          )}
        </p>
        <p :if={@release.shadow == []} id="shadow-none" class="text-sm text-foreground/60">
          {dgettext("showcase", "None yet.")}
        </p>
        <ul :if={@release.shadow != []} id="shadow-rows" class="space-y-2 text-sm">
          <li
            :for={row <- @release.shadow}
            id={"shadow-#{row.run.id}"}
            data-status={row.run.status}
            data-calls={length(row.calls)}
            data-simulated={Enum.count(row.calls, & &1.simulated?)}
          >
            {dgettext("showcase", "Shadow run: %{status}.", status: run_status(row.run.status))}
            <span :if={row.calls != []}>
              {dgettext("showcase", "%{simulated} of %{calls} tool calls simulated.",
                simulated: Enum.count(row.calls, & &1.simulated?),
                calls: length(row.calls)
              )}
            </span>
          </li>
        </ul>
      </.card>
    </li>

    <li id="beat-deploy">
      <.card>
        <h2 class="font-heading text-lg">
          {dgettext("showcase", "19. A deploy changes activate_credential (F3)")}
        </h2>
        <p class="text-sm">
          {dgettext(
            "showcase",
            "Ask for an activation (beat 1) and leave it waiting. Deploy a change to activate_credential, then approve the request as a committee member (beat 2)."
          )}
        </p>
        <p class="text-sm text-foreground/70">
          {dgettext(
            "showcase",
            "Look for: the approval no longer holds. The request goes stale, the reason is manifest_changed, and it never runs. The approval was bound to the release that covered the activation when it was asked for."
          )}
        </p>
        <CaseBeats.demo_build_note fault_controls?={@fault_controls?} />
        <div :if={@fault_controls?}>
          <.button id="fault-deploy" phx-click="fault" phx-value-control="deploy" size="sm">
            {dgettext("showcase", "Deploy a change to activate_credential")}
          </.button>
        </div>
        <p id="activation-release" data-release={release_id(@release.activation.release)}>
          <%= if @release.activation.release do %>
            {dgettext("showcase", "The active release covering it is version %{version}, %{digest}.",
              version: @release.activation.release.version,
              digest: short(@release.activation.release.manifest_digest)
            )}
          <% else %>
            {dgettext("showcase", "No release covers it yet.")}
          <% end %>
        </p>
        <ul id="bound-rows" class="space-y-2 text-sm">
          <li
            :for={row <- bound(@activations, @release.activation.release)}
            id={"bound-#{row.invocation.id}"}
            data-status={row.invocation.status}
            data-reason={row.invocation.error_code}
            data-current={to_string(row.current?)}
            class="flex flex-wrap items-center gap-3"
          >
            <span>{number(@credentials, row.credential_id)}</span>
            <.badge status={row.invocation.status}>{status_label(row.invocation.status)}</.badge>
            <span :if={row.invocation.error_code} class="font-mono text-xs">
              {row.invocation.error_code}
            </span>
            <span :if={row.current?}>
              {dgettext("showcase", "bound to the active release")}
            </span>
            <span :if={not row.current?}>
              {dgettext("showcase", "bound to an earlier release")}
            </span>
          </li>
        </ul>
        <p
          :if={bound(@activations, @release.activation.release) == []}
          class="text-sm text-foreground/60"
        >
          {dgettext("showcase", "No activation request is bound to a release yet.")}
        </p>
      </.card>
    </li>
    """
  end

  attr :candidate, :map, default: nil

  defp candidate(%{candidate: nil} = assigns) do
    ~H"""
    <p id="candidate-none" class="text-sm text-foreground/60">
      {dgettext("showcase", "Not measured yet.")}
    </p>
    """
  end

  defp candidate(assigns) do
    ~H"""
    <div
      id="candidate"
      data-status={@candidate.manifest.status}
      data-run={@candidate.run && @candidate.run.status}
      class="space-y-2 text-sm"
    >
      <p>
        {dgettext("showcase", "Release %{version} of the licence reader: %{status}.",
          version: @candidate.manifest.version,
          status: manifest_status(@candidate.manifest.status)
        )}
      </p>
      <p :if={@candidate.lanes == nil} id="candidate-running">
        {dgettext("showcase", "The suite is running. This page updates when it finishes.")}
      </p>
      <div :if={@candidate.lanes} id="matrix">
        <table class="w-full text-left">
          <thead>
            <tr class="border-b-2 border-border">
              <th class="py-1 pr-3">{dgettext("showcase", "Case")}</th>
              <th class="py-1 pr-3">{dgettext("showcase", "Lane")}</th>
              <th class="py-1 pr-3">{dgettext("showcase", "Result")}</th>
              <th class="py-1 pr-3">{dgettext("showcase", "Read outside text")}</th>
            </tr>
          </thead>
          <tbody>
            <tr
              :for={row <- @candidate.results}
              id={"case-#{row.case_id}"}
              data-status={row.status}
              class="border-b border-border/30"
            >
              <td class="py-1 pr-3 font-mono">{row.case_id}</td>
              <td class="py-1 pr-3">
                {if row.injection?,
                  do: dgettext("showcase", "safety"),
                  else: dgettext("showcase", "quality")}
              </td>
              <td class="py-1 pr-3">
                <.badge status={row.status}>{case_status(row.status)}</.badge>
              </td>
              <td class="py-1 pr-3">
                {if row.tainted, do: dgettext("showcase", "yes"), else: dgettext("showcase", "no")}
              </td>
            </tr>
          </tbody>
        </table>
        <p :if={@candidate.lanes["injection"]} id="injection-lane" class="font-mono text-xs">
          {dgettext(
            "showcase",
            "utility %{utility} · utility under attack %{attacked} · attack success rate %{rate}",
            utility: percent(@candidate.lanes["injection"]["utility"]),
            attacked: percent(@candidate.lanes["injection"]["utility_under_attack"]),
            rate: percent(@candidate.lanes["injection"]["attack_success_rate"])
          )}
        </p>
      </div>
      <div :if={@candidate.problems != []} id="gate-problems">
        <p class="font-heading">{dgettext("showcase", "The gate refused it:")}</p>
        <ul class="ml-4 list-disc">
          <li :for={problem <- @candidate.problems} data-problem>{problem}</li>
        </ul>
      </div>
    </div>
    """
  end

  defp active(credentials), do: Enum.count(credentials, &(&1.status == :active))

  # The activation requests that were bound to a release, with whether it is the active one.
  defp bound(activations, release) do
    for %{invocation: %{release_manifest_id: id}} = row <- activations, is_binary(id) do
      Map.put(row, :current?, release != nil and release.id == id)
    end
  end

  defp number(credentials, id) do
    case Enum.find(credentials, &(&1.id == id)) do
      nil -> ""
      credential -> credential.number
    end
  end

  defp release_id(nil), do: nil
  defp release_id(release), do: release.id

  defp short(nil), do: "—"
  defp short(digest), do: String.slice(digest, 0, 12) <> "…"

  defp percent(nil), do: "—"
  defp percent(value), do: "#{round(value * 100)}%"

  defp manifest_status(:resolved), do: dgettext("showcase", "resolved, not released")
  defp manifest_status(:requested), do: dgettext("showcase", "asked for, awaiting approval")
  defp manifest_status(:active), do: dgettext("showcase", "active")
  defp manifest_status(other), do: to_string(other)

  defp case_status(:passed), do: dgettext("showcase", "passed")
  defp case_status(:failed), do: dgettext("showcase", "failed")
  defp case_status(other), do: to_string(other)

  defp run_status(:finished), do: dgettext("showcase", "finished")
  defp run_status(:running), do: dgettext("showcase", "running")
  defp run_status(other), do: to_string(other)

  defp status_label(:awaiting_approval), do: dgettext("showcase", "awaiting approval")
  defp status_label(:stale), do: dgettext("showcase", "stale")
  defp status_label(:succeeded), do: dgettext("showcase", "succeeded")
  defp status_label(:rejected), do: dgettext("showcase", "rejected")
  defp status_label(other), do: to_string(other)
end
