defmodule AshEnterpriseWeb.DailyLive do
  @moduledoc """
  The daily-loop and operator surfaces (Productivity OS dogfood, epic E6):
  Today, Calendar, Inbox, Slack, People, Approvals, Accounts & syncs and
  Erasure scopes, at `/app/<name>`.

  Each page is one `AshA2ui.LiveRenderer` over a surface in
  `lib/ash_enterprise_web/a2ui/` — the same UI module the ACP server serves
  (`AshEnterprise.Acp.Surfaces`), so the web and the terminal show the same
  rows under the same policies. What this module adds is host chrome, and
  only where the surface cannot say it itself:

    * **Reports run on arrival.** A `:report` component renders empty until
      something dispatches its `"report"` action; Today's agenda and pulse are
      the page, so the host dispatches them through `AshA2ui.ActionHandler`
      once the surface has bootstrapped (and again after every action, so the
      pulse never lags a decision) — the same path a Run click takes, as the
      signed-in actor, off the LiveView process.
    * **Why an inbox is empty.** Inbox and Slack carry a callout naming which
      kind of empty it is — held back by the zone gate (ADR 0042), nothing
      admitted yet for a linked account, or no account linked
      (`AshEnterprise.Canonical.Admission`). It disappears once there is mail.
    * **Compose today's brief.** Today offers a Compose button while the
      signed-in person has no brief for the day (the brief table has no row
      to hang the action on until one exists). The click runs
      `MorningBrief.compose_today` as them, off the LiveView process; the new
      brief reaches the table through the resource's PubSub refresh, and the
      process's compose and decision steps do the same. One brief per day:
      the button does not come back once there is one.
  """

  defmodule Surface do
    @moduledoc false

    defmacro __using__(opts) do
      ui = Keyword.fetch!(opts, :ui)
      reports = Keyword.get(opts, :reports, [])
      inbox = Keyword.get(opts, :inbox)
      compose_brief? = Keyword.get(opts, :compose_brief?, false)

      quote do
        use AshA2ui.LiveRenderer,
          ui: unquote(ui),
          actor_fn: &__MODULE__.actor/1,
          tenant_fn: &__MODULE__.tenant/1,
          pubsub: [
            module: AshEnterprise.PubSub,
            topics: AshEnterprise.Surfaces.topics(unquote(ui))
          ]

        alias AshEnterprise.Security.ActorContext
        alias AshEnterpriseWeb.DailyLive

        @daily_reports unquote(reports)
        @daily_inbox unquote(inbox)
        @daily_compose_brief unquote(compose_brief?)

        def actor(socket), do: socket.assigns[:current_user]
        def tenant(socket), do: ActorContext.tenant(socket.assigns[:current_user])

        @impl true
        def mount(params, session, socket) do
          {:ok, socket} =
            AshA2ui.LiveRenderer.mount(__ash_a2ui_config__(), params, session, socket)

          {:ok,
           socket
           |> DailyLive.mount_inbox_notice(@daily_inbox)
           |> DailyLive.mount_brief_prompt(@daily_compose_brief)}
        end

        @impl true
        def handle_async(:ash_a2ui_surface, result, socket) do
          {:noreply, socket} =
            AshA2ui.LiveRenderer.handle_async(
              __ash_a2ui_config__(),
              :ash_a2ui_surface,
              result,
              socket
            )

          {:noreply, DailyLive.run_reports(socket, unquote(ui), @daily_reports)}
        end

        def handle_async(:daily_reports, result, socket),
          do: {:noreply, DailyLive.push_reports(socket, result)}

        def handle_async(:daily_inbox_notice, result, socket),
          do: {:noreply, DailyLive.put_inbox_notice(socket, result)}

        def handle_async(:daily_brief_prompt, result, socket),
          do: {:noreply, DailyLive.put_brief_prompt(socket, result)}

        def handle_async(:daily_compose_brief, result, socket) do
          {:noreply,
           socket
           |> DailyLive.composed_brief(result)
           |> DailyLive.run_reports(unquote(ui), @daily_reports)}
        end

        @impl true
        def handle_event("a2ui:action", envelope, socket) do
          {:noreply, socket} =
            AshA2ui.LiveRenderer.handle_action(__ash_a2ui_config__(), envelope, socket)

          {:noreply, DailyLive.run_reports(socket, unquote(ui), @daily_reports)}
        end

        def handle_event("a2ui:function_response", payload, socket),
          do:
            AshA2ui.LiveRenderer.handle_function_response(__ash_a2ui_config__(), payload, socket)

        # Only Today offers it; the action itself is authorized as the actor.
        def handle_event("compose_brief", _params, socket) do
          if @daily_compose_brief,
            do: {:noreply, DailyLive.compose_brief(socket)},
            else: {:noreply, socket}
        end

        @impl true
        def render(assigns), do: DailyLive.page(assigns)
      end
    end
  end

  use Phoenix.Component

  require Logger

  import AshEnterpriseWeb.CoreComponents, only: [button: 1, callout: 1]

  import Phoenix.LiveView,
    only: [connected?: 1, push_event: 3, put_flash: 3, start_async: 3]

  alias AshEnterprise.Agents.Actions.ComposeToday
  alias AshEnterprise.Agents.MorningBrief
  alias AshEnterprise.Canonical.{Admission, Conversation}
  alias AshEnterprise.Integration.LinkedAccount
  alias AshEnterprise.Platform.LocalTime
  alias AshEnterprise.Security.ActorContext
  alias AshEnterpriseWeb.Layouts

  @doc false
  def page(assigns) do
    ~H"""
    <Layouts.app flash={@flash} page={assigns[:page]} width="max-w-7xl">
      <.callout :if={@inbox_notice} id="inbox-notice" kind={:warning} role="status">
        {@inbox_notice}
      </.callout>
      <.callout :if={@brief_prompt} id="brief-prompt" kind={:info} role="status">
        <div class="flex flex-wrap items-center justify-between gap-3">
          <span>No morning brief yet today.</span>
          <.button
            id="compose-brief"
            phx-click="compose_brief"
            variant="primary"
            size="sm"
            disabled={@brief_prompt == :composing}
          >
            {if @brief_prompt == :composing, do: "Composing…", else: "Compose today's brief"}
          </.button>
        </div>
      </.callout>
      {AshA2ui.LiveRenderer.surface_container(assigns)}
    </Layouts.app>
    """
  end

  @doc false
  # Dispatches every report through the handler, off the LiveView process
  # (zero jank: the LiveView coordinates, it does not read).
  def run_reports(socket, _ui, []), do: socket

  def run_reports(socket, ui, reports) do
    opts = [actor: socket.assigns.ash_a2ui_actor, tenant: socket.assigns.ash_a2ui_tenant]

    start_async(socket, :daily_reports, fn ->
      Enum.flat_map(reports, &report_messages(ui, &1, opts))
    end)
  end

  # The "report" envelope a Run click sends, handled as the actor. Both
  # outcomes carry messages worth pushing (rows, or the error feedback); the
  # actionResponse is dropped because no client action is waiting on it.
  defp report_messages(ui, name, opts) do
    envelope = %{
      "name" => "report",
      "context" => %{"component" => to_string(name), "params" => %{}}
    }

    {_ok_or_error, messages} = AshA2ui.ActionHandler.handle(ui, envelope, opts)
    Enum.reject(messages, &Map.has_key?(&1, "actionResponse"))
  end

  @doc false
  def push_reports(socket, {:ok, []}), do: socket

  def push_reports(socket, {:ok, messages}),
    do: push_event(socket, "a2ui:messages", %{messages: messages})

  # A failed report read is a missing section, not a crashed page.
  def push_reports(socket, {:exit, _reason}), do: socket

  @doc false
  def mount_brief_prompt(socket, false), do: assign(socket, :brief_prompt, nil)

  def mount_brief_prompt(socket, true) do
    socket = assign(socket, :brief_prompt, nil)

    if connected?(socket) do
      opts = actor_opts(socket)
      start_async(socket, :daily_brief_prompt, fn -> brief_prompt(opts) end)
    else
      socket
    end
  end

  @doc """
  `:compose` when the actor has no morning brief for today on the display
  zone's clock, else nil. Read as the actor.
  """
  def brief_prompt(opts) do
    case ComposeToday.existing(LocalTime.today(), opts[:actor], opts) do
      {:ok, nil} -> :compose
      _brief_or_unreadable -> nil
    end
  end

  @doc false
  def put_brief_prompt(socket, {:ok, prompt}), do: assign(socket, :brief_prompt, prompt)
  def put_brief_prompt(socket, {:exit, _reason}), do: socket

  @doc false
  # One compose in flight: a second click while composing (or after) is a
  # no-op here, and the action's one-per-day identity refuses it anyway.
  def compose_brief(%{assigns: %{brief_prompt: :compose}} = socket) do
    opts = actor_opts(socket)

    socket
    |> assign(:brief_prompt, :composing)
    |> start_async(:daily_compose_brief, fn -> MorningBrief.compose_today(opts) end)
  end

  def compose_brief(socket), do: socket

  @doc false
  def composed_brief(socket, {:ok, {:ok, _status_line}}) do
    socket
    |> assign(:brief_prompt, nil)
    |> put_flash(:info, "Composing today's brief — it will wait for your approval here.")
  end

  def composed_brief(socket, {:ok, {:error, error}}) do
    message =
      case Ash.Error.to_error_class(error) do
        %Ash.Error.Forbidden{} ->
          "You are not allowed to compose a morning brief."

        class ->
          Logger.error("compose_today failed: #{Exception.message(class)}")
          "Today's brief could not be composed — the server log says why."
      end

    socket
    |> assign(:brief_prompt, :compose)
    |> put_flash(:error, message)
  end

  def composed_brief(socket, {:exit, _reason}) do
    socket
    |> assign(:brief_prompt, :compose)
    |> put_flash(:error, "Today's brief could not be composed. Try again.")
  end

  defp actor_opts(socket),
    do: [actor: socket.assigns.ash_a2ui_actor, tenant: socket.assigns.ash_a2ui_tenant]

  @doc false
  def mount_inbox_notice(socket, nil), do: assign(socket, :inbox_notice, nil)

  def mount_inbox_notice(socket, system) do
    socket = assign(socket, :inbox_notice, nil)

    if connected?(socket) do
      actor = socket.assigns[:current_user]
      opts = [actor: actor, tenant: ActorContext.tenant(actor)]
      start_async(socket, :daily_inbox_notice, fn -> inbox_notice(system, opts) end)
    else
      socket
    end
  end

  @doc false
  def put_inbox_notice(socket, {:ok, notice}), do: assign(socket, :inbox_notice, notice)
  def put_inbox_notice(socket, {:exit, _reason}), do: socket

  @doc """
  The callout an inbox page shows, or nil when it has conversations to show.
  Reads as the actor: their conversation count for the vertical and whether
  they have an active linked account for it.
  """
  def inbox_notice(system, opts) do
    count =
      Conversation
      |> Ash.Query.for_read(system, %{}, opts)
      |> Ash.count(opts)

    case count do
      {:ok, 0} ->
        linked? =
          match?(
            {:ok, [_ | _]},
            LinkedAccount.for_operation(Admission.integration(system), nil, opts)
          )

        Admission.empty_message(system, linked?)

      _has_mail_or_unreadable ->
        nil
    end
  end

  defmodule Today do
    @moduledoc "`/app/today` — the day: latest morning brief, today's agenda, the pulse."
    use AshEnterpriseWeb.DailyLive.Surface,
      ui: AshEnterpriseWeb.A2ui.TodayUI,
      reports: [:agenda, :pulse],
      compose_brief?: true
  end

  defmodule Calendar do
    @moduledoc "`/app/calendar` — today, tomorrow and this week, with event detail."
    use AshEnterpriseWeb.DailyLive.Surface, ui: AshEnterpriseWeb.A2ui.CalendarUI
  end

  defmodule Inbox do
    @moduledoc "`/app/inbox` — Gmail threads from the canonical model."
    use AshEnterpriseWeb.DailyLive.Surface, ui: AshEnterpriseWeb.A2ui.InboxUI, inbox: :gmail
  end

  defmodule Slack do
    @moduledoc "`/app/slack` — Slack conversations from the canonical model."
    use AshEnterpriseWeb.DailyLive.Surface, ui: AshEnterpriseWeb.A2ui.SlackUI, inbox: :slack
  end

  defmodule People do
    @moduledoc "`/app/people` — the canonical people directory and a person's events."
    use AshEnterpriseWeb.DailyLive.Surface, ui: AshEnterpriseWeb.A2ui.PeopleUI
  end

  defmodule Approvals do
    @moduledoc "`/app/approvals` — the human tasks waiting on the signed-in person."
    use AshEnterpriseWeb.DailyLive.Surface, ui: AshEnterpriseWeb.A2ui.ApprovalsUI
  end

  defmodule Accounts do
    @moduledoc "`/app/accounts` — linked accounts and their sync health."
    use AshEnterpriseWeb.DailyLive.Surface, ui: AshEnterpriseWeb.A2ui.AccountsUI
  end

  defmodule Erasure do
    @moduledoc "`/app/erasure` — erasure scopes, with the typed-confirmation shred. Operator only."
    use AshEnterpriseWeb.DailyLive.Surface, ui: AshEnterpriseWeb.A2ui.ErasureUI
  end
end
