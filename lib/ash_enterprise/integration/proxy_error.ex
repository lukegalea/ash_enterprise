defmodule AshEnterprise.Integration.ProxyError do
  @moduledoc """
  A typed failure from the provider edge. Adapters branch on `reason`:

  | `reason` | Meaning | Adapter's move |
  |---|---|---|
  | `:unauthorized` | 401, or a provider "token revoked / not authed" | re-link the account; stop syncing it |
  | `:forbidden` | 403 that is not a rate limit (scope missing) | stop; needs a new consent |
  | `:not_found` | 404 from the provider (Gmail: `startHistoryId` too old) | per-provider: reset the cursor or skip |
  | `:gone` | 410 (Calendar: sync token invalid) | call the explicit sync-reset action |
  | `:rate_limited` | 429 (or Google's 403 rate-limit reasons) after retries | snooze the job for `retry_after_ms` |
  | `:bad_request` | 400 | a bug in the declaration or the arguments |
  | `:server_error` | 5xx after retries | retry later |
  | `:connection_not_found` | Nango does not know the connection | the linked account is stale |
  | `:nango_error` | any other error Nango itself raised | inspect `provider_code` |
  | `:provider_error` | Slack `ok: false` with an unmapped code | inspect `provider_code` |
  | `:no_linked_account` | the actor has no active linked account for the integration | link one |
  | `:ambiguous_linked_account` | several, and no `linked_account_id` said which | pass `linked_account_id` |
  | `:not_configured` | `NANGO_SECRET_KEY` is unset | operations, not code |
  | `:transport` | Nango unreachable | retry later |

  Fields carry **no response body and no credential**: `status`,
  `provider_code` (an error *code* such as `"invalid_auth"` or `"NOT_FOUND"`,
  never a message) and `retry_after_ms`.

  `reason/1` digs the reason out of the Ash error class an action returns.
  """

  use Splode.Error,
    fields: [:reason, :integration, :operation, :status, :provider_code, :retry_after_ms],
    class: :unknown

  @type t :: %__MODULE__{}

  @type reason ::
          :unauthorized
          | :forbidden
          | :not_found
          | :gone
          | :rate_limited
          | :bad_request
          | :server_error
          | :connection_not_found
          | :nango_error
          | :provider_error
          | :no_linked_account
          | :ambiguous_linked_account
          | :not_configured
          | :transport

  @impl true
  def message(%__MODULE__{} = error) do
    [
      "provider edge: #{error.reason}",
      error.integration && "integration=#{error.integration}",
      error.operation && "operation=#{error.operation}",
      error.status && "status=#{error.status}",
      error.provider_code && "code=#{error.provider_code}",
      error.retry_after_ms && "retry_after_ms=#{error.retry_after_ms}"
    ]
    |> Enum.reject(&(&1 in [nil, false]))
    |> Enum.join(" ")
  end

  @doc """
  The `ProxyError` inside whatever an action returned, or nil.

      {:error, error} = Gmail.list_history(%{start_history_id: "1"}, actor: actor)
      %ProxyError{reason: :not_found} = ProxyError.unwrap(error)
  """
  def unwrap(%__MODULE__{} = error), do: error
  def unwrap(%{errors: errors}) when is_list(errors), do: Enum.find_value(errors, &unwrap/1)
  def unwrap(%{error: error}), do: unwrap(error)
  def unwrap(_), do: nil

  @doc "The typed reason inside an action's error, or nil when it was not a provider-edge failure."
  def reason(error) do
    case unwrap(error) do
      %__MODULE__{reason: reason} -> reason
      nil -> nil
    end
  end
end
