defmodule AshBrowserTests.Backend.GlitchTip do
  @moduledoc """
  Reads error reports back out of a real GlitchTip, searching issues by the
  `trace_id` tag the host's Sentry wiring sets.

      config :ash_browser_tests, AshBrowserTests.Backend.GlitchTip,
        url: "http://127.0.0.1:8000",
        token: System.get_env("GLITCHTIP_API_TOKEN"),
        organization: "my-org"

  GlitchTip has no spans. Each issue is returned as an `AshBrowserTests.Span` named
  after the issue, with status `:error` and an `exception` event, so
  `AshBrowserTests.Trace.assert_exception/3` works unchanged. `span_id` is the
  issue id.

  Only `{:trace_id, hex}` keys can be searched.
  """

  @behaviour AshBrowserTests.Backend

  alias AshBrowserTests.Span

  @impl true
  def spans_for({:trace_id, hex}, opts) do
    config = Application.get_env(:ash_browser_tests, __MODULE__, []) |> Keyword.merge(opts)
    url = Keyword.fetch!(config, :url)
    organization = Keyword.fetch!(config, :organization)

    request =
      Req.new(
        url: "#{url}/api/0/organizations/#{organization}/issues/",
        params: [query: "trace_id:#{hex}"],
        headers: [{"authorization", "Bearer #{Keyword.get(config, :token, "")}"}],
        retry: false
      )
      |> Req.merge(Keyword.get(config, :req_options, []))

    case Req.request(request) do
      {:ok, %{status: 200, body: issues}} when is_list(issues) ->
        {:ok, Enum.map(issues, &normalize(&1, hex))}

      {:ok, %{status: status, body: body}} ->
        {:error, {:http_status, status, body}}

      {:error, exception} ->
        {:error, exception}
    end
  end

  def spans_for(key, _opts), do: {:error, {:unsupported_key, key}}

  @doc "One GlitchTip issue as a span."
  @spec normalize(map(), String.t()) :: Span.t()
  def normalize(issue, trace_id) do
    metadata = issue["metadata"] || %{}

    %Span{
      trace_id: trace_id,
      span_id: to_string(issue["id"]),
      name: issue["title"] || "",
      status: :error,
      status_message: metadata["value"],
      attributes: %{"glitchtip.count" => issue["count"]},
      events: [
        %{
          name: "exception",
          attributes: %{
            "exception.type" => metadata["type"] || issue["type"],
            "exception.message" => metadata["value"] || issue["title"]
          }
        }
      ],
      source: :glitchtip
    }
  end
end
