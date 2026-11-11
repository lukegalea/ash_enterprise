defmodule AshEnterprise.Telemetry.Attributes do
  @moduledoc """
  The attribute names this package writes. **A contract**: dashboards, saved
  queries and trace assertions depend on these strings, so changing one is a
  breaking change.

  ## Every span

  | Attribute | Value |
  |---|---|
  | `ash.correlation_id` | The server-minted id of the user action. Absent only for work that has none. |
  | `ash.test_key` | The per-test key, in test runs only. |
  | `ash.parent_remote` | `true` when the parent span came from another process or the browser. |

  ## Naming the user action

  These are what let a slow query name its cause: open the Ecto span, walk to the
  root of its trace, and read them.

  | Attribute | Span | Value |
  |---|---|---|
  | `ui.page.path` | browser | The page, with ids replaced by `:id`. |
  | `ui.control.label` | browser | The clicked control's accessible name, truncated. Never an input's value. |
  | `ui.event.name` | browser, `handle_event` | The LiveView event, such as `a2ui:action` or `save`. |
  | `ui.event.type` | browser | The event type, such as `click` or `form`. |
  | `ui.action.name` | `handle_event` | The resolved action, from the `:event_attributes` hook. |
  | `ui.action.resource` | `handle_event` | The resource or UI module it acts on, from the same hook. |
  | `ui.surface.id` | `handle_event` | The rendered surface, when the event carries one. |
  | `ui.view` | `handle_event` | The LiveView or component module. |

  The browser span is named `<page> <control>`, or `<page> <event>` when no control
  was clicked.

  ## Background jobs

  A `send <queue>` PRODUCER span in the request trace, with `messaging.system`
  (`oban`), `messaging.operation.name` (`send`), `messaging.destination.name` (the
  queue), `oban.job.worker` and, for `insert_all`, `messaging.batch.message_count`.
  Job meta carries `traceparent` and `correlation_id`.

  ## Errors

  | Attribute | Value |
  |---|---|
  | `ash.error.class` | `invalid` or `forbidden`, on an Ash span whose failure was an ordinary user-facing one. Status stays unset. |
  | `exception.type`, `exception.message`, `exception.stacktrace` | On a span event named `exception`, which is the only thing SigNoz's Exceptions page reads. |

  The `process.crash` span carries `exception` as an event, and
  `process.crash.initial_call` when it is known.

  ## Reserved

  `ash.*`, `audit.*` and anything naming a correlation id are written only by the
  server. `AshEnterprise.Telemetry.OtlpIngest` strips them from browser spans.

  ## Metrics

  | Metric | Kind | Labels |
  |---|---|---|
  | `oban.queue.depth` | observable gauge | `queue`, `state` |
  | `oban.queue.age` | observable gauge, seconds | `queue`, `state` |
  | `oban.cron.last_success_age` | observable gauge, seconds | `worker` |
  | `oban.job.discards` | counter | `queue` |
  | `oban.lifeline.rescues` | counter | `outcome` |

  ## Errors in Sentry

  Tags `trace_id`, `span_id` and `correlation_id` join a Sentry event to its trace.
  """

  @correlation_id "ash.correlation_id"
  @test_key "ash.test_key"
  @parent_remote "ash.parent_remote"
  @error_class "ash.error.class"
  @reserved_prefixes ["ash.", "audit."]

  @spec correlation_id() :: String.t()
  def correlation_id, do: @correlation_id

  @spec test_key() :: String.t()
  def test_key, do: @test_key

  @spec parent_remote() :: String.t()
  def parent_remote, do: @parent_remote

  @spec error_class() :: String.t()
  def error_class, do: @error_class

  @spec ui_event_name() :: String.t()
  def ui_event_name, do: "ui.event.name"

  @spec ui_view() :: String.t()
  def ui_view, do: "ui.view"

  @spec ui_action_name() :: String.t()
  def ui_action_name, do: "ui.action.name"

  @spec ui_action_resource() :: String.t()
  def ui_action_resource, do: "ui.action.resource"

  @spec ui_surface_id() :: String.t()
  def ui_surface_id, do: "ui.surface.id"

  @doc "Whether a client may not supply this attribute."
  @spec reserved?(String.t()) :: boolean()
  def reserved?(key) when is_binary(key) do
    String.starts_with?(key, @reserved_prefixes) or
      String.contains?(String.downcase(key), "correlation")
  end

  def reserved?(_key), do: true
end
