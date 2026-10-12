defmodule AshEnterprise.Integration.Calendar.SyncError do
  @moduledoc """
  A calendar sync step that stopped for a reason that is not a provider-edge
  failure (those stay `AshEnterprise.Integration.ProxyError`s, so callers
  branch on one `reason/1` either way).

  | `reason` | Meaning |
  |---|---|
  | `:landing_refused` | `Landing.land/2` refused a record; `detail` is the lander's reason atom (`:scoped_landing_not_wired` by default) |
  | `:projection_failed` | a canonical write failed; the cursor did not advance past that page |
  | `:cursor_write_failed` | persisting the cursor failed |
  | `:protocol` | a final events page carried neither `nextPageToken` nor `nextSyncToken` |
  | `:repeated_gone` | 410 Gone again straight after a reset, in the same step |

  Fields are structural only — never a payload, a token or a calendar id —
  because job errors are persisted by Oban.
  """

  use Splode.Error, fields: [:reason, :detail], class: :unknown

  @type reason ::
          :landing_refused
          | :projection_failed
          | :cursor_write_failed
          | :protocol
          | :repeated_gone

  @impl true
  def message(%__MODULE__{reason: reason, detail: nil}), do: "calendar sync: #{reason}"

  def message(%__MODULE__{reason: reason, detail: detail}),
    do: "calendar sync: #{reason} (#{detail})"

  @doc "The `SyncError` inside an action's error, or nil."
  def unwrap(%__MODULE__{} = error), do: error
  def unwrap(%{errors: errors}) when is_list(errors), do: Enum.find_value(errors, &unwrap/1)
  def unwrap(%{error: error}), do: unwrap(error)
  def unwrap(_), do: nil
end
