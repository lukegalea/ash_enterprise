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
  """

  defmodule Surface do
    @moduledoc false

    defmacro __using__(opts) do
      ui = Keyword.fetch!(opts, :ui)
      reports = Keyword.get(opts, :reports, [])
      inbox = Keyword.get(opts, :inbox)

      quote do
        use AshA2ui.LiveRenderer,
          ui: unquote(ui),
          actor_fn: &__MODULE__.actor/1,
          tenant_fn: &__MODULE__.tenant/1,
          pubsub: [
            module: AshEnterprise.PubSub,
            topics: AshEnterpriseWeb.A2ui.Surfaces.topics(unquote(ui))
          ]

        alias AshEnterprise.Security.ActorContext
        alias AshEnterpriseWeb.DailyLive

        @daily_reports unquote(reports)
        @daily_inbox unquote(inbox)

        def actor(socket), do: socket.assigns[:current_user]
        def tenant(socket), do: ActorContext.tenant(socket.assigns[:current_user])

        @impl true
        def mount(params, session, socket) do
          {:ok, socket} =
            AshA2ui.LiveRenderer.mount(__ash_a2ui_config__(), params, session, socket)

          {:ok, DailyLive.mount_inbox_notice(socket, @daily_inbox)}
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

        @impl true
        def handle_event("a2ui:action", envelope, socket) do
          {:noreply, socket} =
            AshA2ui.LiveRenderer.handle_action(__ash_a2ui_config__(), envelope, socket)

          {:noreply, DailyLive.run_reports(socket, unquote(ui), @daily_reports)}
        end

        def handle_event("a2ui:function_response", payload, socket),
          do:
            AshA2ui.LiveRenderer.handle_function_response(__ash_a2ui_config__(), payload, socket)

        @impl true
        def render(assigns), do: DailyLive.page(assigns)
      end
    end
  end

  use Phoenix.Component

  import AshEnterpriseWeb.CoreComponents, only: [callout: 1]
  import Phoenix.LiveView, only: [connected?: 1, push_event: 3, start_async: 3]

  alias AshEnterprise.Canonical.{Admission, Conversation}
  alias AshEnterprise.Integration.LinkedAccount
  alias AshEnterprise.Security.ActorContext
  alias AshEnterpriseWeb.Layouts

  @doc false
  def page(assigns) do
    ~H"""
    <Layouts.app flash={@flash} width="max-w-7xl">
      <.callout :if={@inbox_notice} id="inbox-notice" kind={:warning} role="status">
        {@inbox_notice}
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
      reports: [:agenda, :pulse]
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
