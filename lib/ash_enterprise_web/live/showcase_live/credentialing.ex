defmodule AshEnterpriseWeb.ShowcaseLive.Credentialing do
  @moduledoc """
  The credentialing tour at `/app/showcase/credentialing` (showcase slice 1, see
  `AshEnterprise.Showcase`): governed activation on the synthetic clinic
  (`AshEnterprise.Credentialing.DemoData`), as an ordered list of the scenario's beats over
  the live records, each saying what to do and what to look for. The records open on their
  own declared surfaces (the credentialing workspace, the approvals surface); the tour
  only points at them.

  The beats, in order (1 to 5 are slice 1, 6 to 9 slice 2):

    1. the coordinator asks to activate a credential (`Credential.request_activation`);
    2. a committee member approves it on the approvals surface, and the approval is
       bound to the request's digest;
    3. the credential is corrected while the request waits: the approval no longer
       holds and the request goes stale (F4);
    4. the coordinator's grant is revoked before the activation runs: it is refused
       when it is claimed (F5);
    5. the worker is killed after the registry accepted the activation: the request's
       outcome is unknown until the reconcile sweep asks the registry and settles it,
       without activating twice (F2);
    6. the coordinator starts the licence reader on a credential, which reads its
       documents into findings citing the lines they rest on, shown on the case;
    7. the model times out in the middle of a reading, after its lookups: the run
       resumes from what it recorded and looks nothing up again (F1);
    8. a long bundle exhausts the run's token budget: it waits with a typed reason
       until an administrator extends it (F8);
    9. the clinician asks to be erased: the platform operator shreds their scope, and
       the run's journal and tool-call arguments read as erased while the rows and the
       audit chain stay (F11).

  The licence reader's model turns are recorded transcripts in recorded mode, the
  default (`AshEnterprise.Showcase.RecordedModel`), so the beats need no model and no
  key; live mode sends them to the in-zone profile only.

  The fault panel produces 3 to 5 and 7 (`AshEnterprise.Showcase.Credentialing`); it is
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
  @extension 4_000
  # The licence reader's own budget (`AshEnterprise.Credentialing.LicenceReader`).
  @budget 6_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Process.send_after(self(), :refresh, @refresh_ms)

    {:ok,
     assign(socket,
       locale: "en",
       credentials: [],
       activations: [],
       readings: [],
       recorded: MapSet.new(),
       chain: nil,
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

  def handle_event("read", %{"id" => id}, socket) do
    case Tour.start_reading(id, socket.assigns.current_user) do
      {:ok, _run} ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           dgettext("showcase", "Started. The licence reader reads in the background.")
         )
         |> load()}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, refused(error))}
    end
  end

  def handle_event("extend", %{"id" => id}, socket) do
    case Tour.extend_budget(id, @extension, socket.assigns.current_user) do
      {:ok, _run} ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           dgettext("showcase", "Extended by %{tokens} tokens. The run goes on.",
             tokens: @extension
           )
         )
         |> load()}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, refused(error))}
    end
  end

  def handle_event("erase", %{"id" => id}, socket) do
    actor = socket.assigns.current_user

    case Tour.erase_clinician(id, actor) do
      {:ok, _scope} ->
        {:noreply,
         socket
         |> put_flash(:info, dgettext("showcase", "Erased. The clinician's scope is shredded."))
         |> assign(chain: Tour.chain_verifies?(ActorContext.tenant(actor)))
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

  defp fault("timeout", _params, _tenant) do
    with :ok <- Tour.time_out_model_after_lookups() do
      {:ok,
       dgettext(
         "showcase",
         "Armed. The next reading's model times out in the turn after its lookups."
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
      activations: Tour.activations(actor),
      readings: Tour.readings(actor),
      recorded: MapSet.new(Showcase.RecordedModel.cases(Tour.reader()))
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

  # The credentials the reader has recorded turns for, in recorded mode; every one live.
  defp readable(credentials, :recorded, recorded),
    do: Enum.filter(credentials, &MapSet.member?(recorded, &1.number))

  defp readable(credentials, :live, _recorded), do: credentials

  defp timed_out(readings),
    do: Enum.filter(readings, fn r -> Enum.any?(r.model_calls, &(&1.outcome != :ok)) end)

  defp over_budget(readings),
    do:
      Enum.filter(
        readings,
        &(&1.run.blocked_on == :budget or (&1.run.budget_limit || 0) > @budget)
      )

  defp budget, do: @budget

  defp read_through(readings), do: Enum.filter(readings, &(&1.findings != []))

  defp erased(readings), do: Enum.filter(readings, & &1.erased?)

  defp run_status_label(status) do
    labels = %{
      queued: dgettext("showcase", "queued"),
      running: dgettext("showcase", "running"),
      waiting: dgettext("showcase", "waiting"),
      completed: dgettext("showcase", "completed"),
      failed: dgettext("showcase", "failed"),
      cancelled: dgettext("showcase", "cancelled")
    }

    Map.get(labels, status, to_string(status))
  end

  defp question_label("licence_number"), do: dgettext("showcase", "Licence number")
  defp question_label("licence_valid_until"), do: dgettext("showcase", "Valid until")
  defp question_label(other), do: other

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
              "The licence reader's model turns replay recorded transcripts, so the tour is the same every time and needs no key."
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
            {dgettext(
              "showcase",
              "The coordinator also starts the licence reader. ines@example.com, the clinic director, extends a run's budget. Erasing a clinician takes the platform operator (mix ash_enterprise.platform.grant_operator)."
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

          <li id="beat-read">
            <.card>
              <h2 class="font-heading text-lg">
                {dgettext("showcase", "6. Read a credential's licence documents")}
              </h2>
              <p class="text-sm">
                {dgettext(
                  "showcase",
                  "As the coordinator, start the licence reader on a credential. It reads the certificate and the register extract, each a lookup it calls as a governed tool call, and records what they say."
                )}
              </p>
              <p class="text-sm text-foreground/70">
                {dgettext(
                  "showcase",
                  "Look for: two findings, the licence number and the date it is valid until, each typed and citing the document lines it rests on. The credential's own page shows them too."
                )}
              </p>
              <ul class="space-y-2">
                <li
                  :for={credential <- readable(@credentials, @model_mode, @recorded)}
                  id={"readable-#{credential.id}"}
                  class="flex flex-wrap items-center gap-3"
                >
                  <.link navigate={~p"/app/r/credentials/#{credential.id}"} class="underline">
                    {credential.number}
                  </.link>
                  <span class="text-sm text-foreground/70">{credential.clinician.job_title}</span>
                  <.button
                    id={"read-#{credential.id}"}
                    phx-click="read"
                    phx-value-id={credential.id}
                    size="sm"
                  >
                    {dgettext("showcase", "Read its documents")}
                  </.button>
                </li>
              </ul>
              <.reading_rows id="read" rows={read_through(@readings)} />
            </.card>
          </li>

          <li id="beat-timeout">
            <.card>
              <h2 class="font-heading text-lg">
                {dgettext("showcase", "7. The model times out mid-run (F1)")}
              </h2>
              <p class="text-sm">
                {dgettext(
                  "showcase",
                  "Arm the timeout from the fault panel, then read DEMO-RN-0002. The model answers the first turn, which asks for both lookups, and fails in the middle of the next."
                )}
              </p>
              <p class="text-sm text-foreground/70">
                {dgettext(
                  "showcase",
                  "Look for: the failed model call is recorded and the run keeps its five-minute lease; when it runs out, the recover sweep queues the run again and the same turn is asked again. The lookups ran once each: the repeated turn reads their recorded results."
                )}
              </p>
              <.reading_rows id="timed-out" rows={timed_out(@readings)} />
            </.card>
          </li>

          <li id="beat-budget">
            <.card>
              <h2 class="font-heading text-lg">
                {dgettext("showcase", "8. The token budget runs out (F8)")}
              </h2>
              <p class="text-sm">
                {dgettext(
                  "showcase",
                  "Read DEMO-OT-0003, a long bundle. The reader's budget is %{budget} tokens; this reading needs more.",
                  budget: budget()
                )}
              </p>
              <p class="text-sm text-foreground/70">
                {dgettext(
                  "showcase",
                  "Look for: the run waits on its budget with token_budget, and no model call is made past it. As the clinic director, extend it: it goes on, and its date finding is ambiguous, because the extract states two dates."
                )}
              </p>
              <.reading_rows id="budget" rows={over_budget(@readings)} extend?={true} />
            </.card>
          </li>

          <li id="beat-erase">
            <.card>
              <h2 class="font-heading text-lg">
                {dgettext("showcase", "9. The clinician asks to be erased (F11)")}
              </h2>
              <p class="text-sm">
                {dgettext(
                  "showcase",
                  "Read DEMO-SLT-0004, then, as the platform operator, erase its clinician. The shred cannot be undone: that clinician cannot be read again."
                )}
              </p>
              <p class="text-sm text-foreground/70">
                {dgettext(
                  "showcase",
                  "Look for: every step of the run and every tool call's arguments read as erased, while the rows, their places in the journal and the audit hash chain stay. The findings keep their values and line references; the text they quote was sealed under the clinician's scope too."
                )}
              </p>
              <ul class="space-y-2">
                <li
                  :for={reading <- read_through(@readings)}
                  :if={reading.credential && not reading.erased?}
                  id={"erasable-#{reading.run.id}"}
                  class="flex flex-wrap items-center gap-3"
                >
                  <span>{reading.credential.number}</span>
                  <.button
                    id={"erase-#{reading.credential.id}"}
                    phx-click="erase"
                    phx-value-id={reading.credential.id}
                    size="sm"
                  >
                    {dgettext("showcase", "Erase this clinician")}
                  </.button>
                </li>
              </ul>
              <p :if={@chain == true} id="chain-verifies" class="text-sm">
                {dgettext("showcase", "The audit hash chain verifies after the erasure.")}
              </p>
              <p :if={@chain == false} id="chain-broken" class="text-sm">
                {dgettext("showcase", "The audit hash chain does not verify.")}
              </p>
              <.reading_rows id="erased" rows={erased(@readings)} />
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
            <.button id="fault-timeout" phx-click="fault" phx-value-control="timeout" size="sm">
              {dgettext("showcase", "Time out the model after the lookups")}
            </.button>
          </div>
        </section>

        <section id="activations" class="space-y-3">
          <h2 class="font-heading text-lg">{dgettext("showcase", "Every activation request")}</h2>
          <.beat_rows id="all" rows={@activations} numbers={@numbers} />
        </section>

        <section id="readings" class="space-y-3">
          <h2 class="font-heading text-lg">{dgettext("showcase", "Every reading")}</h2>
          <.reading_rows id="all-readings" rows={@readings} />
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

  attr :id, :string, required: true
  attr :rows, :list, required: true
  attr :extend?, :boolean, default: false

  defp reading_rows(assigns) do
    ~H"""
    <p :if={@rows == []} id={"#{@id}-none"} class="text-sm text-foreground/60">
      {dgettext("showcase", "None yet.")}
    </p>
    <table :if={@rows != []} id={"#{@id}-rows"} class="w-full text-left text-sm">
      <thead>
        <tr class="border-b-2 border-border">
          <th class="py-1 pr-3">{dgettext("showcase", "Credential")}</th>
          <th class="py-1 pr-3">{dgettext("showcase", "Run")}</th>
          <th class="py-1 pr-3">{dgettext("showcase", "Model calls")}</th>
          <th class="py-1 pr-3">{dgettext("showcase", "Lookups")}</th>
          <th class="py-1 pr-3">{dgettext("showcase", "Findings")}</th>
          <th class="py-1 pr-3">{dgettext("showcase", "Journal")}</th>
        </tr>
      </thead>
      <tbody>
        <tr
          :for={row <- @rows}
          id={"#{@id}-#{row.run.id}"}
          data-status={row.run.status}
          data-erased={to_string(row.erased?)}
          class="border-b border-border/30 align-top"
        >
          <td class="py-1 pr-3">
            <.link
              :if={row.credential}
              navigate={~p"/app/r/credentials/#{row.credential.id}"}
              class="underline"
            >
              {row.credential.number}
            </.link>
          </td>
          <td class="py-1 pr-3">
            <.badge status={row.run.status}>{run_status_label(row.run.status)}</.badge>
            <div
              :if={row.run.blocked_on}
              class="font-mono text-xs"
              data-blocked-on={row.run.blocked_on}
            >
              {row.run.blocked_on} · {row.run.error_code}
            </div>
            <div class="text-xs" data-budget={"#{row.run.budget_spent}/#{row.run.budget_limit}"}>
              {dgettext("showcase", "%{spent} of %{limit} tokens",
                spent: row.run.budget_spent || 0,
                limit: row.run.budget_limit || 0
              )}
            </div>
            <.button
              :if={@extend? and row.run.blocked_on == :budget}
              id={"extend-#{row.run.id}"}
              phx-click="extend"
              phx-value-id={row.run.id}
              size="sm"
            >
              {dgettext("showcase", "Extend the budget")}
            </.button>
          </td>
          <td
            class="py-1 pr-3 font-mono text-xs"
            data-model-calls={Enum.map_join(row.model_calls, ",", & &1.outcome)}
          >
            <div :for={call <- row.model_calls}>
              {call.outcome}<span :if={call.error_class}> · {call.error_class}</span>
            </div>
          </td>
          <td
            class="py-1 pr-3 text-xs"
            data-lookups={length(row.lookups)}
            data-attempts={Enum.map_join(row.lookups, ",", & &1.attempt_count)}
          >
            <div :for={lookup <- row.lookups}>
              {dngettext(
                "showcase",
                "%{status}, run %{count} time",
                "%{status}, run %{count} times",
                lookup.attempt_count,
                status: status_label(lookup.status)
              )}
            </div>
          </td>
          <td class="py-1 pr-3 text-xs" data-findings={length(row.findings)}>
            <div
              :for={finding <- row.findings}
              data-question={finding.question}
              data-status={finding.status}
            >
              <span class="font-heading">{question_label(finding.question)}</span>:
              <span class="font-mono">{finding.value || "—"}</span>
              ({finding.status}; {finding.document.title}, {dngettext(
                "showcase",
                "line %{lines}",
                "lines %{lines}",
                length(finding.lines),
                lines: Enum.map_join(finding.lines, ", ", & &1.line)
              )})
            </div>
          </td>
          <td class="py-1 pr-3 text-xs" data-steps={length(row.steps)}>
            <span :if={not row.erased?}>
              {dngettext(
                "showcase",
                "%{count} step, recorded",
                "%{count} steps, recorded",
                length(row.steps)
              )}
            </span>
            <span :if={row.erased?}>
              {dngettext(
                "showcase",
                "%{count} step, erased",
                "%{count} steps, erased",
                length(row.steps)
              )}
            </span>
          </td>
        </tr>
      </tbody>
    </table>
    """
  end
end
