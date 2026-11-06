defmodule AshEnterprise.Credentialing.RegistryApi.Transport do
  @moduledoc """
  The credential registry's only HTTP client (Iron Law #20), over `AshOperations.Http`.

  `config/0` reads `Application.get_env(:ash_enterprise, #{inspect(__MODULE__)})` on every
  call, never at compile time: the registry's key is a runtime secret of the same class as
  the Nango secret key (ADR 0011).

    * **A registry is configured** (`CREDENTIAL_REGISTRY_URL`, set in `config/runtime.exs`)
      when the config carries a `:base_url` and a `:api_key`. A URL without a key is
      `{:error, :not_configured}`: the call fails before anything is sent, and the key is never
      defaulted.
    * **No URL** (dev, demo, test) falls back to the in-process fake
      (`AshEnterprise.Credentialing.Registry.FakeProvider`, over the ETS stub), so the template
      still runs offline exactly as the stub did. Its residency is `:in_cluster`.

  `residency/0` says where the registry runs, for the disclosure gate
  (`AshEnterprise.Credentialing.RegistryDisclosureGate`): `:in_cluster` or `:sub_processor`.

  `classify/1` reads the error envelope's `code` and `requestId` only, never its `message`,
  so a provider's wording cannot reach a log or an invocation row.
  """

  use AshOperations.Http

  alias AshEnterprise.Credentialing.Registry.FakeProvider

  @fallback_url "http://credential-registry.local"

  @impl AshOperations.Http
  def config do
    settings = Application.get_env(:ash_enterprise, __MODULE__) || []

    case Keyword.get(settings, :base_url) do
      url when url in [nil, ""] -> {:ok, fake(settings)}
      url -> real(url, Keyword.get(settings, :api_key), settings)
    end
  end

  @doc "Where the registry runs: `:in_cluster` (the fake) or the configured residency."
  @spec residency() :: :in_cluster | :sub_processor
  def residency do
    settings = Application.get_env(:ash_enterprise, __MODULE__) || []

    case Keyword.get(settings, :base_url) do
      url when url in [nil, ""] -> :in_cluster
      _url -> Keyword.get(settings, :residency, :sub_processor)
    end
  end

  @impl AshOperations.Http
  def classify(%{body: %{"code" => code} = body} = response) when is_binary(code) do
    %{
      reason: AshOperations.Http.status_reason(response.status),
      provider_code: code,
      request_id: request_id(body)
    }
  end

  def classify(response), do: AshOperations.Http.by_status(response)

  defp request_id(%{"requestId" => id}) when is_binary(id), do: id
  defp request_id(_body), do: nil

  defp real(_url, key, _settings) when key in [nil, ""], do: {:error, :not_configured}

  defp real(url, key, settings) do
    {:ok,
     %{base_url: url, auth: {:bearer, key}}
     |> Map.merge(Map.new(Keyword.take(settings, [:req_options, :sleep, :base_backoff_ms])))}
  end

  defp fake(settings) do
    base = %{
      base_url: @fallback_url,
      req_options: [plug: FakeProvider]
    }

    Map.merge(base, Map.new(Keyword.take(settings, [:sleep, :base_backoff_ms, :req_options])))
  end
end
