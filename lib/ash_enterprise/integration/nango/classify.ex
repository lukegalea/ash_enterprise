defmodule AshEnterprise.Integration.Nango.Classify do
  @moduledoc """
  Turns a proxied response into success or a typed error reason.

  Three profiles, chosen per resource by `nango do errors ... end`:

    * `:http` — status codes only.
    * `:google` — `:http`, plus Google's error envelope: a 403 whose reason is
      `rateLimitExceeded`/`userRateLimitExceeded` is a rate limit (retried like
      a 429), and `provider_code` is the first `errors[].reason`.
    * `:slack` — `:http`, plus Slack's `200 {"ok": false, "error": ...}`
      bodies, mapped by error code.

  Errors raised by **Nango itself** (rather than passed through from the
  provider) carry a string `error.code`; providers proxied here use numeric
  codes or none. `unknown_connection` becomes `:connection_not_found`.
  *Unverified against a live Nango*: the exact Nango error codes were taken from
  its public docs, not observed.

  Classification only reads error codes and statuses. It never copies a
  response body into the error.
  """

  @type response :: %{status: pos_integer(), body: term(), headers: map()}
  @type error_fields :: %{
          reason: AshEnterprise.Integration.ProxyError.reason(),
          status: pos_integer() | nil,
          provider_code: String.t() | nil
        }

  @google_rate_limit_reasons ~w(rateLimitExceeded userRateLimitExceeded)

  @slack_unauthorized ~w(not_authed invalid_auth account_inactive token_revoked token_expired
                         no_permission_for_user user_is_deactivated)
  @slack_forbidden ~w(missing_scope not_allowed_token_type not_in_channel no_permission
                      ekm_access_denied access_denied)
  @slack_not_found ~w(channel_not_found user_not_found)

  @doc "Classify a response under a profile."
  @spec classify(:http | :google | :slack, response()) :: :ok | {:error, error_fields()}
  def classify(profile, %{status: status} = response) when status in 200..299 do
    case profile do
      :slack -> slack_body(response)
      _ -> :ok
    end
  end

  def classify(profile, %{status: status, body: body}) do
    case nango_code(body) do
      code when is_binary(code) -> {:error, nango_error(status, code)}
      nil -> {:error, provider_error(profile, status, body)}
    end
  end

  # --- Nango's own errors ------------------------------------------------------

  defp nango_code(%{"error" => %{"code" => code}}) when is_binary(code), do: code
  defp nango_code(_), do: nil

  defp nango_error(status, "unknown_connection"),
    do: fields(:connection_not_found, status, "unknown_connection")

  defp nango_error(status, code) do
    reason =
      cond do
        status == 429 -> :rate_limited
        status == 401 -> :unauthorized
        Regex.match?(~r/token|secret|credential|auth/, code) -> :unauthorized
        true -> :nango_error
      end

    fields(reason, status, code)
  end

  # --- provider errors ---------------------------------------------------------

  defp provider_error(:google, 403 = status, body) do
    code = google_code(body)

    if code in @google_rate_limit_reasons,
      do: fields(:rate_limited, status, code),
      else: fields(:forbidden, status, code)
  end

  defp provider_error(:google, status, body),
    do: fields(by_status(status), status, google_code(body))

  defp provider_error(:slack, status, body),
    do: fields(by_status(status), status, slack_code(body))

  defp provider_error(_profile, status, _body), do: fields(by_status(status), status, nil)

  defp by_status(400), do: :bad_request
  defp by_status(401), do: :unauthorized
  defp by_status(403), do: :forbidden
  defp by_status(404), do: :not_found
  defp by_status(410), do: :gone
  defp by_status(429), do: :rate_limited
  defp by_status(status) when status >= 500, do: :server_error
  defp by_status(_status), do: :bad_request

  defp google_code(%{"error" => %{"errors" => [%{"reason" => reason} | _]}})
       when is_binary(reason),
       do: reason

  defp google_code(%{"error" => %{"status" => status}}) when is_binary(status), do: status
  defp google_code(_), do: nil

  # --- Slack -------------------------------------------------------------------

  defp slack_body(%{body: %{"ok" => false} = body, status: status}) do
    code = slack_code(body)

    reason =
      cond do
        code in @slack_unauthorized -> :unauthorized
        code in @slack_forbidden -> :forbidden
        code in @slack_not_found -> :not_found
        code == "ratelimited" -> :rate_limited
        # A pagination cursor Slack no longer accepts is the same move as a
        # Calendar 410: restart the walk explicitly.
        code == "invalid_cursor" -> :gone
        true -> :provider_error
      end

    {:error, fields(reason, status, code)}
  end

  defp slack_body(_response), do: :ok

  defp slack_code(%{"error" => code}) when is_binary(code), do: code
  defp slack_code(_), do: nil

  defp fields(reason, status, code), do: %{reason: reason, status: status, provider_code: code}
end
