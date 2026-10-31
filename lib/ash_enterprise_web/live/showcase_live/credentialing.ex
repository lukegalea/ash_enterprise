defmodule AshEnterpriseWeb.ShowcaseLive.Credentialing do
  @moduledoc """
  The credentialing tour at `/app/showcase/credentialing` (showcase slice 1, see
  `AshEnterprise.Showcase`): governed activation on the synthetic clinic
  (`AshEnterprise.Credentialing.DemoData`), as an ordered list of the scenario's beats over
  the live records, each saying what to do and what to look for. The records open on their
  own declared surfaces (the credentialing workspace, the approvals surface); the tour
  only points at them.

  The beats, in order:

    1. the coordinator asks to activate a credential (`Credential.request_activation`);
    2. a committee member approves it on the approvals surface, and the approval is
       bound to the request's digest;
    3. the credential is corrected while the request waits: the approval no longer
       holds and the request goes stale (F4);
    4. the coordinator's grant is revoked before the activation runs: it is refused
       when it is claimed (F5);
    5. the worker is killed after the registry accepted the activation: the request's
       outcome is unknown until the reconcile sweep asks the registry and settles it,
       without activating twice (F2).

  The fault panel produces 3 to 5 (`AshEnterprise.Showcase.Credentialing`); it is
  rendered, and its events are honoured, only when the demo flag is on
  (`AshEnterprise.Showcase.fault_controls?/0`). Everything else reads and acts as the
  signed-in person, so the beats show what that person may see.

  Copy is in English and French (`?locale=fr`), through the `showcase` Gettext domain.
  Records are read in `handle_params` and again every few seconds once connected,
  because the outcomes arrive from background jobs.
  """

  use AshEnterpriseWeb, :live_view

  alias AshEnterprise.Credentialing, as: Clinic
  alias AshEnterprise.Credentialing.Credential
  alias AshEnterprise.Security.ActorContext
  alias AshEnterprise.Showcase
  alias AshEnterprise.Showcase.Credentialing, as: Tour
  alias AshEnterpriseWeb.Layouts

  @locales ~w(en fr)
  @refresh_ms 3_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Process.send_after(self(), :refresh, @refresh_ms)

    {:ok,
     assign(socket,
       locale: "en",
       credentials: [],
       activations: [],
       fault_controls?: Showcase.fault_controls?(),
       model_mode: Showcase.model_mode(),
       live_model: Showcase.live_model()
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    locale = if params["locale"] in @locales, do: params["locale"], else: "en"
    Gettext.put_locale(AshEnterpriseWeb.Gettext, locale)

    {:noreply, socket |> assign(locale: locale) |> translate_header() |> load()}
  end

  @impl true
  def handle_info(:refresh, socket) do
    Process.send_after(self(), :refresh, @refresh_ms)
    {:noreply, load(socket)}
  end

  @impl true
  def handle_event("raise", %{"id" => id}, socket) do
    case Clinic.request_activation(id, opts(socket)) do
      {:ok, %{"status" => "awaiting_approval"}} ->
        {:noreply,
         socket
         |> put_flash(:info, dgettext("showcase", "Asked. The request waits for approval."))
         |> load()}

      {:ok, %{"status" => status}} ->
        {:noreply,
         socket
         |> put_flash(:info, dgettext("showcase", "Asked: %{status}.", status: status))
         |> load()}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, refused(error))}
    end
  end

  def handle_event("fault", %{"control" => control} = params, socket) do
    actor = socket.assigns.current_user
    tenant = ActorContext.tenant(actor)

    result =
      if Ash.can?({Credential, :read}, actor, tenant: tenant) do
        fault(control, params, tenant)
      else
        {:error, :forbidden}
      end

    case result do
      {:ok, message} ->
        {:noreply, socket |> put_flash(:info, message) |> load()}

      {:error, :fault_controls_off} ->
        {:noreply,
         put_flash(socket, :error, dgettext("showcase", "The fault panel is off here."))}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, refused(error))}
    end
  end

  defp fault("kill", _params, _tenant) do
    with :ok <- Tour.kill_after_registry_accepts() do
      {:ok,
       dgettext(
         "showcase",
         "Armed. The next activation's worker dies after the registry accepts it."
       )}
    end
  end

  defp fault("correct", %{"id" => id}, tenant) do
    with {:ok, _credential} <- Tour.correct_during_approval(id, tenant) do
      {:ok, dgettext("showcase", "Corrected the credential's expiry date.")}
    end
  end

  defp fault("revoke", _params, tenant) do
    with {:ok, count} <- Tour.revoke_requester_grant(tenant) do
      {:ok,
       dngettext(
         "showcase",
         "Revoked the coordinator's role (%{count} assignment).",
         "Revoked the coordinator's role (%{count} assignments).",
         count
       )}
    end
  end

  defp fault("restore", _params, tenant) do
    with {:ok, _clinic} <- Tour.restore(tenant) do
      {:ok, dgettext("showcase", "Ran the clinic's demo data again.")}
    end
  end

  defp fault(_control, _params, _tenant), do: {:error, :unknown_control}

  defp refused(%Ash.Error.Forbidden{}),
    do: dgettext("showcase", "Not allowed for the person signed in.")

  defp refused(_error), do: dgettext("showcase", "That did not work.")

  defp opts(socket) do
    actor = socket.assigns.current_user
    [actor: actor, tenant: ActorContext.tenant(actor)]
  end

  defp load(socket) do
    actor = socket.assigns.current_user
    credentials = Tour.credentials(actor)

    assign(socket,
      credentials: credentials,
      numbers: Map.new(credentials, &{&1.id, &1.number}),
      activations: Tour.activations(actor)
    )
  end

  # The page header is the registry's label and blurb, in English; the tour's own.
  defp translate_header(%{assigns: %{page: %{surface: %{} = surface} = page}} = socket) do
    surface = %{
      surface
      | label: dgettext("showcase", "Credentialing tour"),
        blurb:
          dgettext(
            "showcase",
            "A guided tour of governed activation: ask, approve, and what happens when the world changes in between."
          )
    }

    assign(socket, page: %{page | surface: surface})
  end

  defp translate_header(socket), do: socket

  defp with_status(activations, statuses),
    do: Enum.filter(activations, &(&1.invocation.status in statuses))

  defp pending(credentials), do: Enum.filter(credentials, &(&1.status == :pending))

  defp short(nil), do: "—"
  defp short(digest), do: String.slice(digest, 0, 12) <> "…"

  defp status_label(status) do
    labels = %{
      awaiting_approval: dgettext("showcase", "awaiting approval"),
      ready: dgettext("showcase", "ready"),
      executing: dgettext("showcase", "executing"),
      succeeded: dgettext("showcase", "succeeded"),
      failed: dgettext("showcase", "failed"),
      rejected: dgettext("showcase", "rejected"),
      stale: dgettext("showcase", "stale"),
      outcome_unknown: dgettext("showcase", "outcome unknown"),
      cancelled: dgettext("showcase", "cancelled")
    }

    Map.get(labels, status, to_string(status))
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} page={assigns[:page]} width="max-w-5xl">
      <:toolbar>
        <nav id="showcase-locale" class="flex gap-2 text-sm" aria-label="Language">
          <.link
            patch={~p"/app/showcase/credentialing?locale=en"}
            aria-current={@locale == "en" && "true"}
            class={["underline", @locale == "en" && "font-heading"]}
          >
            English
          </.link>
          <.link
            patch={~p"/app/showcase/credentialing?locale=fr"}
            aria-current={@locale == "fr" && "true"}
            class={["underline", @locale == "fr" && "font-heading"]}
          >
            Français
          </.link>
        </nav>
      </:toolbar>

      <div class="space-y-8">
        <section id="showcase-mode" class="flex flex-wrap items-center gap-3 text-sm">
          <.badge :if={@model_mode == :recorded} id="model-mode" tone="cyan" sticker>
            {dgettext("showcase", "Model mode: recorded")}
          </.badge>
          <.badge :if={@model_mode == :live} id="model-mode" tone="orange" sticker>
            {dgettext("showcase", "Model mode: live")}
          </.badge>
          <span :if={@model_mode == :recorded} class="text-foreground/70">
            {dgettext(
              "showcase",
              "Model turns replay recorded transcripts, so the tour is the same every time. No beat in this slice calls a model."
            )}
          </span>
          <span :if={@model_mode == :live} class="text-foreground/70">
            <%= case @live_model do %>
              <% {:ok, label} -> %>
                {dgettext("showcase", "Model turns go to the in-zone profile, %{model}.",
                  model: label
                )}
              <% :not_configured -> %>
                {dgettext(
                  "showcase",
                  "Live mode uses the in-zone profile only, and none is configured."
                )}
            <% end %>
          </span>
        </section>

        <section id="showcase-personas" class="text-sm text-foreground/80">
          <p>
            {dgettext(
              "showcase",
              "Sign in as rosa@example.com, the coordinator, to ask; as kenji@example.com or amaka@example.com, the committee, to approve. The password is password1234."
            )}
          </p>
          <p>
            {dgettext("showcase", "Signed in as %{email}.", email: to_string(@current_user.email))}
            <.link navigate={~p"/app/credentialing"} class="underline">
              {dgettext("showcase", "Open the credentials")}
            </.link>
          </p>
        </section>

        <ol id="beats" class="space-y-6">
          <li id="beat-raise">
            <.card>
              <h2 class="font-heading text-lg">
                {dgettext("showcase", "1. Ask to activate a credential")}
              </h2>
              <p class="text-sm">
                {dgettext(
                  "showcase",
                  "As the coordinator, ask for a pending credential to be activated. Nothing reaches the registry yet."
                )}
              </p>
              <p class="text-sm text-foreground/70">
                {dgettext(
                  "showcase",
                  "Look for: the request waits for approval, with a digest of exactly what it will do."
                )}
              </p>
              <ul class="space-y-2">
                <li
                  :for={credential <- pending(@credentials)}
                  id={"pending-#{credential.id}"}
                  class="flex flex-wrap items-center gap-3"
                >
                  <.link navigate={~p"/app/r/credentials/#{credential.id}"} class="underline">
                    {credential.number}
                  </.link>
                  <span class="text-sm text-foreground/70">{credential.clinician.job_title}</span>
                  <.button
                    id={"raise-#{credential.id}"}
                    phx-click="raise"
                    phx-value-id={credential.id}
                    size="sm"
                  >
                    {dgettext("showcase", "Ask to activate")}
                  </.button>
                </li>
              </ul>
            </.card>
          </li>

          <li id="beat-approve">
            <.card>
              <h2 class="font-heading text-lg">
                {dgettext("showcase", "2. A committee member approves it")}
              </h2>
              <p class="text-sm">
                {dgettext(
                  "showcase",
                  "As a committee member, open the request's approval and approve it. The coordinator cannot approve their own request."
                )}
              </p>
              <p class="text-sm text-foreground/70">
                {dgettext(
                  "showcase",
                  "Look for: the approval digest is the digest of the request's target, arguments and the credential's version, so it approves this request and no other. Once approved, it runs within a minute."
                )}
              </p>
              <.beat_rows
                id="awaiting"
                rows={with_status(@activations, [:awaiting_approval])}
                numbers={@numbers}
              />
            </.card>
          </li>

          <li id="beat-stale">
            <.card>
              <h2 class="font-heading text-lg">
                {dgettext("showcase", "3. The credential changes during approval (F4)")}
              </h2>
              <p class="text-sm">
                {dgettext(
                  "showcase",
                  "Ask again, then correct the credential from the fault panel while the request waits, then approve it."
                )}
              </p>
              <p class="text-sm text-foreground/70">
                {dgettext(
                  "showcase",
                  "Look for: the request goes stale with subject_changed. The approval was for the credential as it was, so it does not run."
                )}
              </p>
              <.beat_rows id="stale" rows={with_status(@activations, [:stale])} numbers={@numbers} />
            </.card>
          </li>

          <li id="beat-revoked">
            <.card>
              <h2 class="font-heading text-lg">
                {dgettext("showcase", "4. The coordinator's grant is revoked (F5)")}
              </h2>
              <p class="text-sm">
                {dgettext(
                  "showcase",
                  "Ask again, revoke the coordinator's role from the fault panel, then approve it. Restore the role afterwards."
                )}
              </p>
              <p class="text-sm text-foreground/70">
                {dgettext(
                  "showcase",
                  "Look for: it runs as the coordinator rebuilt from their grants now, so it fails as denied, and the registry is never asked."
                )}
              </p>
              <.beat_rows id="denied" rows={with_status(@activations, [:failed])} numbers={@numbers} />
            </.card>
          </li>

          <li id="beat-reconciled">
            <.card>
              <h2 class="font-heading text-lg">
                {dgettext("showcase", "5. The worker dies after the registry accepted (F2)")}
              </h2>
              <p class="text-sm">
                {dgettext(
                  "showcase",
                  "Arm the kill from the fault panel, then ask and approve. The worker dies holding a five-minute lease, after the registry accepted the activation and before anything was recorded."
                )}
              </p>
              <p class="text-sm text-foreground/70">
                {dgettext(
                  "showcase",
                  "Look for: when the lease runs out the request is outcome unknown, never run again. The reconcile sweep asks the registry, which holds the activation, and settles it succeeded via reconcile_with, with the registry's reference. The registry took it once. The credential's own row still says pending: reconciliation records the outcome on the request, it does not write the credential."
                )}
              </p>
              <.beat_rows
                id="reconciled"
                rows={
                  Enum.filter(
                    @activations,
                    &(&1.invocation.status in [:executing, :outcome_unknown] or
                        not is_nil(&1.invocation.reconciled_via))
                  )
                }
                numbers={@numbers}
              />
            </.card>
          </li>
        </ol>

        <section
          :if={@fault_controls?}
          id="fault-panel"
          class="space-y-3 rounded-base border-2 border-dashed border-border p-4"
        >
          <h2 class="font-heading text-lg">{dgettext("showcase", "Fault panel")}</h2>
          <p class="text-sm text-foreground/70">
            {dgettext(
              "showcase",
              "Demo only. Each control does what another person or a failure would, through the application's own actions and fault points."
            )}
          </p>
          <ul class="space-y-2">
            <li
              :for={row <- with_status(@activations, [:awaiting_approval])}
              :if={row.credential_id}
              class="flex flex-wrap items-center gap-3"
            >
              <.button
                id={"fault-correct-#{row.invocation.id}"}
                phx-click="fault"
                phx-value-control="correct"
                phx-value-id={row.credential_id}
                size="sm"
              >
                {dgettext("showcase", "Correct %{number} during approval",
                  number: Map.get(@numbers, row.credential_id, "")
                )}
              </.button>
            </li>
          </ul>
          <div class="flex flex-wrap gap-3">
            <.button id="fault-revoke" phx-click="fault" phx-value-control="revoke" size="sm">
              {dgettext("showcase", "Revoke the coordinator's grant")}
            </.button>
            <.button id="fault-restore" phx-click="fault" phx-value-control="restore" size="sm">
              {dgettext("showcase", "Restore the clinic")}
            </.button>
            <.button id="fault-kill" phx-click="fault" phx-value-control="kill" size="sm">
              {dgettext("showcase", "Kill the worker after the registry accepts")}
            </.button>
          </div>
        </section>

        <section id="activations" class="space-y-3">
          <h2 class="font-heading text-lg">{dgettext("showcase", "Every activation request")}</h2>
          <.beat_rows id="all" rows={@activations} numbers={@numbers} />
        </section>
      </div>
    </Layouts.app>
    """
  end

  attr :id, :string, required: true
  attr :rows, :list, required: true
  attr :numbers, :map, required: true

  defp beat_rows(assigns) do
    ~H"""
    <p :if={@rows == []} id={"#{@id}-none"} class="text-sm text-foreground/60">
      {dgettext("showcase", "None yet.")}
    </p>
    <table :if={@rows != []} id={"#{@id}-rows"} class="w-full text-left text-sm">
      <thead>
        <tr class="border-b-2 border-border">
          <th class="py-1 pr-3">{dgettext("showcase", "Credential")}</th>
          <th class="py-1 pr-3">{dgettext("showcase", "Status")}</th>
          <th class="py-1 pr-3">{dgettext("showcase", "Why")}</th>
          <th class="py-1 pr-3">{dgettext("showcase", "Approval digest")}</th>
          <th class="py-1 pr-3">{dgettext("showcase", "Registry")}</th>
        </tr>
      </thead>
      <tbody>
        <tr
          :for={row <- @rows}
          id={"#{@id}-#{row.invocation.id}"}
          data-status={row.invocation.status}
          class="border-b border-border/30 align-top"
        >
          <td class="py-1 pr-3">
            <.link
              :if={row.credential_id}
              navigate={~p"/app/r/credentials/#{row.credential_id}"}
              class="underline"
            >
              {Map.get(@numbers, row.credential_id, row.credential_id)}
            </.link>
          </td>
          <td class="py-1 pr-3">
            <.badge status={row.invocation.status}>{status_label(row.invocation.status)}</.badge>
            <.link
              :if={row.task_id && row.invocation.status == :awaiting_approval}
              id={"#{@id}-approve-#{row.invocation.id}"}
              navigate={~p"/app/r/approvals/#{row.task_id}"}
              class="ml-2 underline"
            >
              {dgettext("showcase", "Open the approval")}
            </.link>
          </td>
          <td class="py-1 pr-3 font-mono text-xs">
            {Enum.join(
              Enum.reject(
                [
                  row.invocation.failure_class,
                  row.invocation.error_code,
                  row.invocation.reconciled_via &&
                    dgettext("showcase", "via %{via}", via: row.invocation.reconciled_via)
                ],
                &is_nil/1
              ),
              " · "
            )}
          </td>
          <td class="py-1 pr-3 font-mono text-xs">
            {short(row.invocation.approval_digest)}
            <span :if={row.bound? == true} data-bound="true">
              {dgettext("showcase", "bound to this request")}
            </span>
            <span :if={row.bound? == false} data-bound="false">
              {dgettext("showcase", "does not match")}
            </span>
          </td>
          <td class="py-1 pr-3 text-xs" data-registry-activations={row.registry_activations}>
            {dngettext(
              "showcase",
              "%{count} activation",
              "%{count} activations",
              row.registry_activations
            )}
            <span :if={row.invocation.effect_ref} class="font-mono">
              {row.invocation.effect_ref}
            </span>
          </td>
        </tr>
      </tbody>
    </table>
    """
  end
end
