defmodule AshEnterpriseWeb.ShowcaseLive.CaseBeats do
  @moduledoc """
  The credentialing case beats of the tour (`AshEnterpriseWeb.ShowcaseLive.Credentialing`,
  beats 10 to 15, showcase slice 3), and the note a beat that needs a fault control shows
  when the demo flag is off.

  The page owns the events and the data (`AshEnterprise.Showcase.Case.cases/1`); this
  renders them. Copy is in English and French through the `showcase` Gettext domain.
  """

  use AshEnterpriseWeb, :html

  alias AshEnterprise.Credentialing.CaseProcess
  alias AshEnterpriseWeb.ShowcaseLive.TourIndex

  @doc """
  Says, in place, that a beat's control runs in the demo build, when the fault panel is off.
  """
  attr :fault_controls?, :boolean, required: true

  def demo_build_note(assigns) do
    ~H"""
    <p :if={not @fault_controls?} class="demo-build-note text-sm italic text-foreground/70">
      {dgettext(
        "showcase",
        "This beat needs a fault control, which runs in the demo build only. The fault panel is off here, so read it as a description of what the demo build shows."
      )}
    </p>
    """
  end

  attr :records, :map, required: true
  attr :cases, :list, required: true
  attr :credentials, :list, required: true
  attr :activations, :list, required: true
  attr :fault_controls?, :boolean, required: true

  def beats(assigns) do
    assigns =
      assign(assigns,
        await: CaseProcess.await_node(),
        unopened: unopened(assigns.credentials, assigns.cases)
      )

    ~H"""
    <li id="beat-case">
      <.card>
        <h2 class="font-heading text-lg">{dgettext("showcase", "10. Open a credential's case")}</h2>
        <p class="text-sm">
          {dgettext(
            "showcase",
            "As the coordinator, open a credential's case. It is a BPMN process: the two evidence checks run side by side, as you."
          )}
        </p>
        <p class="text-sm text-foreground/70">
          {dgettext(
            "showcase",
            "Look for: DEMO-PH-0006 has no licence document filed, so its documents check is refused while the expiry check goes on. The others pass both checks and go to the committee."
          )}
        </p>
        <ul class="space-y-2">
          <li
            :for={credential <- @unopened}
            id={"unopened-#{credential.id}"}
            class="flex flex-wrap items-center gap-3"
          >
            <.link navigate={~p"/app/r/credentials/#{credential.id}"} class="underline">
              {credential.number}
            </.link>
            <span class="text-sm text-foreground/70">{credential.clinician.job_title}</span>
            <.button
              id={"open-case-#{credential.id}"}
              phx-click="open_case"
              phx-value-id={credential.id}
              size="sm"
            >
              {dgettext("showcase", "Open the case")}
            </.button>
          </li>
        </ul>
        <.case_rows id="cases" rows={@cases} />
        <TourIndex.explore beat={10} records={@records} />
      </.card>
    </li>

    <li id="beat-checks">
      <.card>
        <h2 class="font-heading text-lg">
          {dgettext("showcase", "11. One of the parallel checks fails (F7)")}
        </h2>
        <p class="text-sm">
          {dgettext(
            "showcase",
            "Open DEMO-PH-0006's case. The documents check is refused by a business rule, which is a process error, not a crash."
          )}
        </p>
        <p class="text-sm text-foreground/70">
          {dgettext(
            "showcase",
            "Look for: the documents check failed with licence_document_missing and the expiry check succeeded, side by side. The case took the check's error boundary, asked for the document once, and waits for it. The join fires when both branches arrive."
          )}
        </p>
        <.case_rows id="refused" rows={Enum.filter(@cases, &refused?/1)} />
        <TourIndex.explore beat={11} records={@records} />
      </.card>
    </li>

    <li id="beat-webhook">
      <.card>
        <h2 class="font-heading text-lg">
          {dgettext("showcase", "12. The document webhook arrives twice, and out of order (F6)")}
        </h2>
        <p class="text-sm">
          {dgettext(
            "showcase",
            "Deliver the filing system's document-received webhook twice for a case that waits for it, or once for a credential whose case is not open yet, then open the case."
          )}
        </p>
        <p class="text-sm text-foreground/70">
          {dgettext(
            "showcase",
            "Look for: however many deliveries and in whatever order, one continuation. The repeated delivery is recorded once, and the early one is found when the case starts to wait."
          )}
        </p>
        <TourIndex.fault_note fault_controls?={@fault_controls?} recorded?={@records[12] != nil} />
        <ul :if={@fault_controls?} class="space-y-2">
          <li
            :for={row <- Enum.filter(@cases, &(@await in &1.waiting_for))}
            id={"webhook-#{row.credential.id}"}
            class="flex flex-wrap items-center gap-3"
          >
            <span>{row.credential.number}</span>
            <.button
              id={"fault-webhook-twice-#{row.credential.id}"}
              phx-click="fault"
              phx-value-control="webhook_twice"
              phx-value-id={row.credential.id}
              size="sm"
            >
              {dgettext("showcase", "Deliver the webhook twice")}
            </.button>
          </li>
          <li
            :for={credential <- @unopened}
            id={"webhook-early-#{credential.id}"}
            class="flex flex-wrap items-center gap-3"
          >
            <span>{credential.number}</span>
            <.button
              id={"fault-webhook-early-#{credential.id}"}
              phx-click="fault"
              phx-value-control="webhook"
              phx-value-id={credential.id}
              size="sm"
            >
              {dgettext("showcase", "Deliver the webhook before its case waits")}
            </.button>
          </li>
        </ul>
        <.case_rows id="webhooks" rows={Enum.filter(@cases, &(&1.deliveries != []))} />
        <TourIndex.explore beat={12} records={@records} />
      </.card>
    </li>

    <li id="beat-committee">
      <.card>
        <h2 class="font-heading text-lg">
          {dgettext("showcase", "13. The committee decides")}
        </h2>
        <p class="text-sm">
          {dgettext(
            "showcase",
            "As a committee member, open the case's task on the task board and approve it. The coordinator owns the credential and cannot decide on it."
          )}
        </p>
        <p class="text-sm text-foreground/70">
          {dgettext(
            "showcase",
            "Look for: the task completes with the outcome approved and the case moves on to its timer. A rejection ends the case."
          )}
        </p>
        <p>
          <.link id="case-tasks" navigate={~p"/app/tasks"} class="underline">
            {dgettext("showcase", "Open the task board")}
          </.link>
        </p>
        <.case_rows id="reviews" rows={Enum.filter(@cases, &(&1.review != nil))} packet?={true} />
        <TourIndex.explore beat={13} records={@records} />
      </.card>
    </li>

    <li id="beat-timer">
      <.card>
        <h2 class="font-heading text-lg">
          {dgettext("showcase", "14. The re-credentialing timer")}
        </h2>
        <p class="text-sm">
          {dgettext(
            "showcase",
            "Once the committee approves, the case waits for the credential's re-credentialing date."
          )}
        </p>
        <p class="text-sm text-foreground/70">
          {dgettext(
            "showcase",
            "Look for: the date on the case. It is a durable job, a row in the database, so a restart or a deploy does not lose it."
          )}
        </p>
        <.case_rows id="timers" rows={Enum.filter(@cases, &(&1.timer != nil))} />
        <TourIndex.explore beat={14} records={@records} />
      </.card>
    </li>

    <li id="beat-acp">
      <.card>
        <h2 class="font-heading text-lg">
          {dgettext("showcase", "15. An approval over ACP survives a restart")}
        </h2>
        <p class="text-sm">
          {dgettext(
            "showcase",
            "From a coding agent or an ACP client signed in as a committee member, ask to approve a request, then restart the application."
          )}
        </p>
        <p class="text-sm text-foreground/70">
          {dgettext(
            "showcase",
            "Look for: the request is still waiting, on the approvals surface too, and a client that sends it again finds the same request instead of making a second. Its permission request is a stored invocation, not a memory of the session."
          )}
        </p>
        <p id="acp-waiting" data-waiting={waiting(@activations)}>
          {dngettext(
            "showcase",
            "%{count} request waits for approval now.",
            "%{count} requests wait for approval now.",
            waiting(@activations)
          )}
          <.link navigate={~p"/app/approvals"} class="underline">
            {dgettext("showcase", "Open the approvals")}
          </.link>
        </p>
        <TourIndex.explore beat={15} records={@records} />
      </.card>
    </li>
    """
  end

  attr :id, :string, required: true
  attr :rows, :list, required: true
  attr :packet?, :boolean, default: false

  defp case_rows(assigns) do
    ~H"""
    <p :if={@rows == []} id={"#{@id}-none"} class="text-sm text-foreground/60">
      {dgettext("showcase", "None yet.")}
    </p>
    <ul :if={@rows != []} id={"#{@id}-rows"} class="space-y-3 text-sm">
      <li
        :for={row <- @rows}
        id={"#{@id}-#{row.instance.id}"}
        data-status={row.instance.status}
        data-deliveries={length(row.deliveries)}
        data-continuations={row.continuations}
        class="border-b border-border/30 pb-2"
      >
        <div class="flex flex-wrap items-center gap-3">
          <.link navigate={~p"/app/r/credentials/#{row.credential.id}"} class="underline">
            {row.credential.number}
          </.link>
          <.badge status={row.instance.status}>{status_label(row.instance.status)}</.badge>
          <span :if={row.instance.outcome} class="font-mono text-xs">{row.instance.outcome}</span>
          <.link
            :if={@packet? && row.review}
            id={"#{@id}-packet-#{row.instance.id}"}
            navigate={~p"/app/r/approvals/#{row.review.id}"}
            class="underline"
          >
            {dgettext("showcase", "Open the review packet")}
          </.link>
          <.link
            id={"#{@id}-explore-#{row.instance.id}"}
            navigate={TourIndex.explorer_path({:process_instance, row.instance.id})}
            class="underline"
          >
            {dgettext("showcase", "Open in explorer")}
          </.link>
        </div>
        <ul class="ml-4 list-disc">
          <li :for={check <- row.checks} data-check-status={check.status}>
            {check_label(check.target)}: {check_status(check)}
          </li>
          <li :if={row.requests != []} data-requests={length(row.requests)}>
            {dngettext(
              "showcase",
              "Asked for the document %{count} time.",
              "Asked for the document %{count} times.",
              length(row.requests)
            )}
          </li>
          <li :if={row.waiting_for != []} data-waiting-for={Enum.join(row.waiting_for, ",")}>
            {dgettext("showcase", "Waiting at: %{nodes}.", nodes: Enum.join(row.waiting_for, ", "))}
          </li>
          <li :if={row.deliveries != []}>
            {dgettext(
              "showcase",
              "%{deliveries} webhook delivery recorded, %{continuations} continuation.",
              deliveries: length(row.deliveries),
              continuations: row.continuations
            )}
          </li>
          <li :if={row.review} data-review-status={row.review.status}>
            {dgettext("showcase", "Committee review: %{status}.", status: row.review.status)}
          </li>
          <li :if={row.timer} data-due={Date.to_iso8601(DateTime.to_date(row.timer.due_at))}>
            {dgettext("showcase", "Re-credentialing due %{date}.",
              date: Calendar.strftime(row.timer.due_at, "%Y-%m-%d")
            )}
          </li>
        </ul>
      </li>
    </ul>
    """
  end

  # The credentials that have no case yet.
  defp unopened(credentials, cases) do
    open = MapSet.new(cases, & &1.credential.id)
    Enum.reject(credentials, &(MapSet.member?(open, &1.id) or &1.status == :active))
  end

  defp refused?(row), do: Enum.any?(row.checks, &(&1.status == :failed))

  defp waiting(activations),
    do: Enum.count(activations, &(&1.invocation.status == :awaiting_approval))

  defp check_label("AshEnterprise.Credentialing.Credential.check_documents"),
    do: dgettext("showcase", "Documents check")

  defp check_label("AshEnterprise.Credentialing.Credential.check_expiry"),
    do: dgettext("showcase", "Expiry check")

  defp check_label(other), do: other

  defp check_status(%{status: :failed, error_code: code}) when is_binary(code),
    do: dgettext("showcase", "refused (%{code})", code: code)

  defp check_status(%{status: :succeeded}), do: dgettext("showcase", "passed")
  defp check_status(%{status: status}), do: to_string(status)

  defp status_label(:running), do: dgettext("showcase", "running")
  defp status_label(:completed), do: dgettext("showcase", "completed")
  defp status_label(:failed), do: dgettext("showcase", "failed")
  defp status_label(other), do: to_string(other)
end
