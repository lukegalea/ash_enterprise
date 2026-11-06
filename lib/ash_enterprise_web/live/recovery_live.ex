defmodule AshEnterpriseWeb.RecoveryLive do
  @moduledoc """
  `/app/recovery`: what an operator does about an invocation that went wrong.

    * `:index` lists the invocations the signed-in person may read whose outcome is
      uncertain, then the most recent, each with its shared status
      (`AshAgent.Execution.Status`).
    * `:show` (`/app/recovery/:id`) is one invocation: what it asked for, its status,
      and the acts `AshEnterprise.Execution.Recovery` offers for that status, each
      saying what it does before anyone does it.

  The acts:

    * **Settle** an uncertain outcome: it happened; it did not and must not run; or it
      did not and runs again under the same request. Offered once a person has been
      asked, never as a plain retry: an uncertain effect may have happened.
    * **Simulate** a rerun: what it would run now, checked without running it.
      Nothing is created.
    * **Rerun**: a new request with a new key, linked to this one, run as the person.
      The page says what will run again before they ask.
    * **Cancel**: stops a request that has not run. The page says what cancelling does
      not undo.

  Every act runs through `AshEnterprise.Execution`'s code interface as the signed-in
  person, so its own policy decides (Iron Law #11), and is recorded with who did it and
  why (`AshEnterprise.Execution.Intervention`), which the page and the trace show. Data
  loads in `handle_params/3`; a shown invocation is followed over its PubSub topic
  once connected.
  """

  use AshEnterpriseWeb, :live_view

  alias AshAgent.Execution.Status
  alias AshEnterprise.Accounts
  alias AshEnterprise.Execution
  alias AshEnterprise.Execution.Recovery
  alias AshEnterprise.Security.ActorContext
  alias AshEnterpriseWeb.Layouts

  @recent 30
  @refresh_ms 3_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) and socket.assigns.live_action == :index,
      do: Process.send_after(self(), :refresh, @refresh_ms)

    {:ok,
     assign(socket,
       page_title: dgettext("recovery", "Recovery"),
       invocation: nil,
       uncertain: [],
       recent: [],
       interventions: [],
       reruns: [],
       people: %{},
       preview: nil,
       subscribed: nil
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, load(socket, params)}
  end

  @impl true
  def handle_info(:refresh, socket) do
    Process.send_after(self(), :refresh, @refresh_ms)
    {:noreply, load(socket, %{})}
  end

  def handle_info(%Phoenix.Socket.Broadcast{topic: "invocations:" <> _id}, socket) do
    {:noreply, reload(socket)}
  end

  # --- the acts: each is the code interface, as the signed-in person -------------

  @impl true
  def handle_event(_act, _params, %{assigns: %{invocation: nil}} = socket) do
    {:noreply,
     put_flash(socket, :error, dgettext("recovery", "There is nothing here to act on."))}
  end

  def handle_event("simulate", _params, socket) do
    case Execution.simulate_rerun(socket.assigns.invocation.id, opts(socket)) do
      {:ok, preview} -> {:noreply, assign(socket, preview: preview)}
      {:error, error} -> {:noreply, put_flash(socket, :error, refused(error))}
    end
  end

  def handle_event("rerun", %{"reason" => reason}, socket) do
    case Execution.rerun_invocation(socket.assigns.invocation.id, reason, opts(socket)) do
      {:ok, intervention} ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           dgettext("recovery", "Rerun asked as a new request. This one stays as it was.")
         )
         |> push_navigate(to: ~p"/app/recovery/#{intervention.rerun_id}")}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, refused(error))}
    end
  end

  def handle_event("cancel", %{"reason" => reason}, socket) do
    case Execution.cancel_invocation(socket.assigns.invocation.id, reason, opts(socket)) do
      {:ok, _intervention} ->
        {:noreply,
         socket |> put_flash(:info, dgettext("recovery", "Cancel recorded.")) |> reload()}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, refused(error))}
    end
  end

  def handle_event("settle", %{"reason" => reason, "resolution" => resolution}, socket)
      when resolution in ~w(succeeded failed retry) do
    case Execution.resolve_invocation(
           socket.assigns.invocation.id,
           String.to_existing_atom(resolution),
           reason,
           opts(socket)
         ) do
      {:ok, _intervention} ->
        {:noreply,
         socket
         |> put_flash(:info, dgettext("recovery", "Recorded. The outcome is applied next."))
         |> reload()}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, refused(error))}
    end
  end

  def handle_event("settle", _params, socket) do
    {:noreply, put_flash(socket, :error, dgettext("recovery", "Say what happened."))}
  end

  # --- loading --------------------------------------------------------------------

  defp load(%{assigns: %{live_action: :show}} = socket, %{"id" => id}) do
    socket |> assign(preview: nil) |> load_one(id) |> follow(id)
  end

  defp load(%{assigns: %{live_action: :show}} = socket, _params), do: reload(socket)

  defp load(socket, _params) do
    opts = opts(socket)

    assign(socket,
      uncertain:
        Execution.list_invocations!(
          Keyword.put(opts, :query,
            filter: [status: :outcome_unknown],
            sort: [created_on: :desc],
            limit: @recent
          )
        ),
      recent:
        Execution.list_invocations!(
          Keyword.put(opts, :query, sort: [created_on: :desc], limit: @recent)
        )
    )
  end

  defp reload(%{assigns: %{invocation: %{id: id}}} = socket), do: load_one(socket, id)
  defp reload(socket), do: socket

  defp load_one(socket, id) do
    opts = opts(socket)

    case Execution.get_invocation(id, Keyword.put(opts, :load, [:resolution_task])) do
      {:ok, invocation} ->
        interventions =
          Execution.list_interventions!(
            Keyword.put(opts, :query,
              filter: [invocation_id: invocation.id],
              sort: [created_on: :asc]
            )
          )

        reruns =
          Execution.list_invocations!(
            Keyword.put(opts, :query,
              filter: [rerun_of_id: invocation.id],
              sort: [created_on: :asc]
            )
          )

        assign(socket,
          invocation: invocation,
          interventions: interventions,
          reruns: reruns,
          people: people(interventions, socket),
          page_title: dgettext("recovery", "Recovery")
        )

      {:error, _not_readable} ->
        socket
        |> assign(invocation: nil, interventions: [], reruns: [])
        |> put_flash(:error, dgettext("recovery", "No invocation you can read has this id."))
    end
  end

  # The person who did each act, by email where the viewer may read them.
  defp people(interventions, socket) do
    me = socket.assigns.current_user

    interventions
    |> Enum.map(& &1.owner_id)
    |> Enum.uniq()
    |> Map.new(fn
      id when id == me.id ->
        {id, to_string(me.email)}

      id ->
        case Accounts.get_user(id, opts(socket)) do
          {:ok, user} -> {id, to_string(user.email)}
          {:error, _not_readable} -> {id, "person:#{id}"}
        end
    end)
  end

  defp follow(%{assigns: %{subscribed: id}} = socket, id), do: socket

  defp follow(socket, id) do
    cond do
      not connected?(socket) ->
        socket

      old = socket.assigns.subscribed ->
        AshEnterpriseWeb.Endpoint.unsubscribe("invocations:#{old}")
        subscribe(socket, id)

      true ->
        subscribe(socket, id)
    end
  end

  defp subscribe(socket, id) do
    :ok = AshEnterpriseWeb.Endpoint.subscribe("invocations:#{id}")
    assign(socket, subscribed: id)
  end

  defp opts(socket) do
    actor = socket.assigns.current_user
    [actor: actor, tenant: ActorContext.tenant(actor)]
  end

  defp refused(%Ash.Error.Forbidden{}),
    do: dgettext("recovery", "Not allowed for the person signed in.")

  defp refused(%{errors: [_ | _] = errors}),
    do: Enum.map_join(errors, " ", &message/1)

  defp refused(_error), do: dgettext("recovery", "That did not work.")

  defp message(%{field: field, message: message} = error) when is_binary(message) do
    text = Enum.reduce(Map.get(error, :vars, []), message, &interpolate/2)
    if field, do: "#{field} #{text}", else: text
  end

  defp message(error) when is_exception(error), do: Exception.message(error)
  defp message(_error), do: dgettext("recovery", "That did not work.")

  defp interpolate({key, value}, text), do: String.replace(text, "%{#{key}}", to_string(value))

  # --- rendering --------------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} page={assigns[:page]} width="max-w-5xl">
      <%= if @live_action == :show do %>
        <.invocation_page
          :if={@invocation}
          invocation={@invocation}
          interventions={@interventions}
          reruns={@reruns}
          people={@people}
          preview={@preview}
        />
        <.link navigate={~p"/app/recovery"} class="text-sm underline" id="back-to-recovery">
          {dgettext("recovery", "Every invocation")}
        </.link>
      <% else %>
        <.index uncertain={@uncertain} recent={@recent} />
      <% end %>
    </Layouts.app>
    """
  end

  attr :uncertain, :list, required: true
  attr :recent, :list, required: true

  defp index(assigns) do
    ~H"""
    <section id="uncertain" class="space-y-3">
      <h2 class="font-heading text-lg">{dgettext("recovery", "Uncertain outcomes")}</h2>
      <p class="text-sm text-foreground/70">
        {dgettext(
          "recovery",
          "Each may have taken effect outside the application. Nothing runs again by itself: settle what happened first."
        )}
      </p>
      <.rows id="uncertain-rows" rows={@uncertain} />
    </section>
    <section id="recent" class="mt-6 space-y-3">
      <h2 class="font-heading text-lg">{dgettext("recovery", "Recent invocations")}</h2>
      <.rows id="recent-rows" rows={@recent} />
    </section>
    """
  end

  attr :id, :string, required: true
  attr :rows, :list, required: true

  defp rows(assigns) do
    ~H"""
    <p :if={@rows == []} id={"#{@id}-none"} class="text-sm text-foreground/60">
      {dgettext("recovery", "None.")}
    </p>
    <table :if={@rows != []} id={@id} class="w-full text-left text-sm">
      <thead>
        <tr class="border-b-2 border-border">
          <th class="py-1 pr-3">{dgettext("recovery", "Target")}</th>
          <th class="py-1 pr-3">{dgettext("recovery", "Status")}</th>
          <th class="py-1 pr-3">{dgettext("recovery", "Asked")}</th>
        </tr>
      </thead>
      <tbody>
        <tr
          :for={row <- @rows}
          id={"#{@id}-#{row.id}"}
          data-status={shared(row)}
          class="border-b border-border/30"
        >
          <td class="py-1 pr-3">
            <.link navigate={~p"/app/recovery/#{row.id}"} class="underline font-mono text-xs">
              {short_target(row.target)}
            </.link>
          </td>
          <td class="py-1 pr-3"><.status invocation={row} /></td>
          <td class="py-1 pr-3 text-xs">{Calendar.strftime(row.created_on, "%Y-%m-%d %H:%M")}</td>
        </tr>
      </tbody>
    </table>
    """
  end

  attr :invocation, :map, required: true

  defp status(assigns) do
    ~H"""
    <.badge tone={tone(shared(@invocation))} data-status={shared(@invocation)}>
      {status_label(shared(@invocation))}
    </.badge>
    <span class="ml-1 font-mono text-xs text-foreground/60">{@invocation.status}</span>
    """
  end

  attr :invocation, :map, required: true
  attr :interventions, :list, required: true
  attr :reruns, :list, required: true
  attr :people, :map, required: true
  attr :preview, :map, default: nil

  defp invocation_page(assigns) do
    ~H"""
    <article id={"invocation-#{@invocation.id}"} class="space-y-4">
      <.card>
        <h2 class="font-heading text-lg font-mono break-all">{@invocation.target}</h2>
        <dl class="mt-2 grid grid-cols-[auto_1fr] gap-x-4 gap-y-1 text-sm">
          <dt>{dgettext("recovery", "Status")}</dt>
          <dd id="status" data-status={shared(@invocation)}><.status invocation={@invocation} /></dd>
          <dt>{dgettext("recovery", "Key")}</dt>
          <dd id="invocation-key" class="font-mono text-xs break-all">
            {@invocation.invocation_key}
          </dd>
          <dt :if={@invocation.error_code}>{dgettext("recovery", "Why")}</dt>
          <dd :if={@invocation.error_code} class="font-mono text-xs">
            {Enum.join(
              Enum.reject([@invocation.failure_class, @invocation.error_code], &is_nil/1),
              " "
            )}
          </dd>
          <dt :if={@invocation.rerun_of_id}>{dgettext("recovery", "Reruns")}</dt>
          <dd :if={@invocation.rerun_of_id}>
            <.link
              id="rerun-of"
              navigate={~p"/app/recovery/#{@invocation.rerun_of_id}"}
              class="underline font-mono text-xs"
            >
              {@invocation.rerun_of_id}
            </.link>
          </dd>
          <dt :if={@invocation.effect_ref}>{dgettext("recovery", "Effect")}</dt>
          <dd :if={@invocation.effect_ref} class="font-mono text-xs">
            {@invocation.effect_system} {@invocation.effect_ref}
          </dd>
        </dl>
      </.card>

      <.uncertain :if={@invocation.status == :outcome_unknown} invocation={@invocation} />

      <.rerun
        :if={Recovery.rerun(@invocation) == :ok}
        invocation={@invocation}
        preview={@preview}
      />

      <.cancel :if={Recovery.cancel(@invocation) == :ok} invocation={@invocation} />

      <section :if={@reruns != []} id="reruns" class="space-y-2">
        <h3 class="font-heading">{dgettext("recovery", "Rerun as")}</h3>
        <ul class="text-sm">
          <li :for={rerun <- @reruns} id={"rerun-#{rerun.id}"}>
            <.link navigate={~p"/app/recovery/#{rerun.id}"} class="underline font-mono text-xs">
              {rerun.invocation_key}
            </.link>
            <.status invocation={rerun} />
          </li>
        </ul>
      </section>

      <section id="interventions" class="space-y-2">
        <h3 class="font-heading">{dgettext("recovery", "What people did")}</h3>
        <p :if={@interventions == []} id="interventions-none" class="text-sm text-foreground/60">
          {dgettext("recovery", "Nothing yet.")}
        </p>
        <ol :if={@interventions != []} class="space-y-1 text-sm">
          <li
            :for={intervention <- @interventions}
            id={"intervention-#{intervention.id}"}
            data-act={intervention.act}
          >
            <span class="font-mono text-xs">
              {Calendar.strftime(intervention.created_on, "%Y-%m-%d %H:%M")}
            </span>
            <strong class="intervention-actor">{Map.get(@people, intervention.owner_id)}</strong>
            <span class="intervention-act">{act_label(intervention)}</span>:
            <q class="intervention-reason">{intervention.reason}</q>
          </li>
        </ol>
      </section>
    </article>
    """
  end

  attr :invocation, :map, required: true

  defp uncertain(assigns) do
    ~H"""
    <.card id="uncertain-outcome">
      <h3 class="font-heading">{dgettext("recovery", "The outcome is uncertain")}</h3>
      <p class="text-sm">
        {dgettext(
          "recovery",
          "It may have taken effect: its answer was lost after it reached outside the application. It is never run again as it stands, because running it again could do it twice."
        )}
      </p>
      <%= if Recovery.settle(@invocation) == :ok do %>
        <.form for={%{}} id="settle-form" phx-submit="settle" class="mt-3 space-y-3">
          <fieldset class="space-y-1 text-sm">
            <legend class="font-heading">{dgettext("recovery", "What happened?")}</legend>
            <label class="flex items-start gap-2">
              <input type="radio" name="resolution" value="succeeded" id="settle-succeeded" />
              {dgettext("recovery", "It happened. Record it as done; nothing runs.")}
            </label>
            <label class="flex items-start gap-2">
              <input type="radio" name="resolution" value="failed" id="settle-failed" />
              {dgettext("recovery", "It did not happen. Record it as failed; nothing runs.")}
            </label>
            <label class="flex items-start gap-2">
              <input type="radio" name="resolution" value="retry" id="settle-retry" />
              {dgettext(
                "recovery",
                "It did not happen, and I checked. Run it again under this same request."
              )}
            </label>
          </fieldset>
          <.reason id="settle-reason" />
          <.button id="settle" type="submit" variant="primary" size="sm">
            {dgettext("recovery", "Record what happened")}
          </.button>
        </.form>
      <% else %>
        <p id="settle-waiting" class="mt-2 text-sm text-foreground/70">
          {dgettext(
            "recovery",
            "The outside system is being asked what happened. If it cannot say, a person is asked here."
          )}
        </p>
      <% end %>
    </.card>
    """
  end

  attr :invocation, :map, required: true
  attr :preview, :map, default: nil

  defp rerun(assigns) do
    ~H"""
    <.card id="rerun-card">
      <h3 class="font-heading">{dgettext("recovery", "Rerun")}</h3>
      <ul id="rerun-statement" class="list-disc pl-5 text-sm space-y-1">
        <li>
          {dgettext(
            "recovery",
            "Runs %{target} again, with the arguments this request recorded, as a new request of yours: a new key, linked to this one.",
            target: short_target(@invocation.target)
          )}
        </li>
        <li :for={line <- rerun_lines(@invocation.effects)}>{line}</li>
        <li>{dgettext("recovery", "This request stays as it is.")}</li>
      </ul>
      <div class="mt-3 flex flex-wrap gap-3">
        <.button id="simulate" phx-click="simulate" size="sm">
          {dgettext("recovery", "Simulate the rerun")}
        </.button>
      </div>
      <.preview :if={@preview} preview={@preview} />
      <.form for={%{}} id="rerun-form" phx-submit="rerun" class="mt-3 space-y-3">
        <.reason id="rerun-reason" />
        <.button id="rerun" type="submit" variant="primary" size="sm">
          {dgettext("recovery", "Rerun as a new request")}
        </.button>
      </.form>
    </.card>
    """
  end

  attr :preview, :map, required: true

  defp preview(assigns) do
    ~H"""
    <div id="simulation" class="mt-3 rounded-base border-2 border-dashed border-border p-3 text-sm">
      <p class="font-heading">
        {dgettext("recovery", "Simulated. Nothing was created and nothing ran.")}
      </p>
      <ul class="list-disc pl-5">
        <li :if={@preview[:resolves] == false} id="simulation-unresolved">
          {dgettext("recovery", "The target no longer resolves.")}
        </li>
        <li :if={@preview[:definition_changed]} id="simulation-changed">
          {dgettext(
            "recovery",
            "The target changed since this request: a rerun runs it as it is now."
          )}
        </li>
        <li :if={@preview[:arguments] == :valid} id="simulation-arguments">
          {dgettext("recovery", "The recorded arguments are still valid.")}
        </li>
        <li :if={@preview[:arguments] not in [nil, :valid]} id="simulation-arguments">
          {dgettext("recovery", "The recorded arguments would be refused: %{why}",
            why: arguments_text(@preview[:arguments])
          )}
        </li>
        <li :if={@preview[:approval] not in [nil, :none]} id="simulation-approval">
          {dgettext("recovery", "It would wait for approval (%{approval}).",
            approval: @preview[:approval]
          )}
        </li>
        <li :if={@preview[:rerunnable] == false} id="simulation-refusal">
          {dgettext("recovery", "A rerun would be refused: %{why}", why: @preview[:refusal])}
        </li>
      </ul>
    </div>
    """
  end

  attr :invocation, :map, required: true

  defp cancel(assigns) do
    ~H"""
    <.card id="cancel-card">
      <h3 class="font-heading">{dgettext("recovery", "Cancel")}</h3>
      <p id="cancel-statement" class="text-sm">
        {cancel_text(@invocation.status)}
        {dgettext(
          "recovery",
          "Completed effects are not reversed: anything already done stays done, and undoing it is a separate act."
        )}
      </p>
      <.form for={%{}} id="cancel-form" phx-submit="cancel" class="mt-3 space-y-3">
        <.reason id="cancel-reason" />
        <.button id="cancel" type="submit" size="sm">
          {dgettext("recovery", "Cancel this request")}
        </.button>
      </.form>
    </.card>
    """
  end

  attr :id, :string, required: true

  defp reason(assigns) do
    ~H"""
    <label class="block text-sm">
      <span class="font-heading">{dgettext("recovery", "Why")}</span>
      <textarea
        id={@id}
        name="reason"
        required
        maxlength="2000"
        rows="2"
        class="mt-1 w-full rounded-base border-2 border-border bg-secondary-background p-2"
      ></textarea>
    </label>
    """
  end

  # --- text ---------------------------------------------------------------------------

  defp shared(invocation), do: invocation |> Status.invocation() |> elem(0)

  defp tone(:succeeded), do: "green"
  defp tone(:failed), do: "red"
  defp tone(:cancelled), do: "neutral"
  defp tone(status) when status in [:waiting, :running], do: "main"
  defp tone(_uncertain), do: "yellow"

  defp status_label(:waiting), do: dgettext("recovery", "waiting")
  defp status_label(:running), do: dgettext("recovery", "running")
  defp status_label(:succeeded), do: dgettext("recovery", "succeeded")
  defp status_label(:failed), do: dgettext("recovery", "failed")
  defp status_label(:cancelled), do: dgettext("recovery", "cancelled")
  defp status_label(_uncertain), do: dgettext("recovery", "uncertain")

  defp act_label(%{act: :rerun}), do: dgettext("recovery", "reran it")
  defp act_label(%{act: :cancel}), do: dgettext("recovery", "cancelled it")

  defp act_label(%{act: :resolve, resolution: :succeeded}),
    do: dgettext("recovery", "settled it as done")

  defp act_label(%{act: :resolve, resolution: :failed}),
    do: dgettext("recovery", "settled it as failed")

  defp act_label(%{act: :resolve, resolution: :retry}),
    do: dgettext("recovery", "settled it as not done, to run again")

  defp act_label(_intervention), do: dgettext("recovery", "acted")

  defp rerun_lines(effects) when is_map(effects) do
    [
      outside_line(effects["open_world"], effects["idempotent"]),
      approval_line(effects["approval"])
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp rerun_lines(_effects),
    do: [dgettext("recovery", "Its effects declaration was not recorded: simulate it first.")]

  defp outside_line(false, _idempotent),
    do: dgettext("recovery", "It changes only this application's records.")

  defp outside_line(_open_world, true),
    do:
      dgettext(
        "recovery",
        "It calls outside the application again; its declaration says a repeat has no further effect."
      )

  defp outside_line(_open_world, _idempotent),
    do:
      dgettext(
        "recovery",
        "It calls outside the application again. If the first call took effect, this is a second one."
      )

  defp approval_line(approval) when approval in [nil, "none", :none], do: nil

  defp approval_line(approval),
    do:
      dgettext("recovery", "It waits for approval again (%{approval}), as any new request does.",
        approval: approval
      )

  defp cancel_text(status) when status in [:executing, :dispatched],
    do:
      dgettext(
        "recovery",
        "It is already running: cancelling records that it should stop, and whoever settles it decides how it ends."
      )

  defp cancel_text(_status),
    do: dgettext("recovery", "Cancelling stops this request before it runs.")

  defp arguments_text(messages) when is_list(messages), do: Enum.join(messages, "; ")
  defp arguments_text(:erased), do: dgettext("recovery", "they were erased")
  defp arguments_text(_other), do: dgettext("recovery", "they cannot be read")

  defp short_target(target) when is_binary(target),
    do: target |> String.split(".") |> Enum.take(-2) |> Enum.join(".")

  defp short_target(_target), do: ""
end
