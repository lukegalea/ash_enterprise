defmodule AshEnterprise.Telemetry.BanditSpans do
  @moduledoc false

  # Replaces OpentelemetryBandit's handler with one that:
  #
  #   * opens no span for the paths in `Settings.dropped_paths/0`, so the browser's
  #     span flush does not trace itself. The span is never created, because a
  #     processor cannot drop one without also skipping the processors after it;
  #   * remembers the failing span before the library closes it;
  #   * cannot be detached by a failure.

  alias AshEnterprise.Telemetry.FailedSpan
  alias AshEnterprise.Telemetry.Settings

  @skip {__MODULE__, :skip}
  @events [
    [:bandit, :request, :start],
    [:bandit, :request, :stop],
    [:bandit, :request, :exception]
  ]

  @doc "Swaps the handler. Must run straight after `OpentelemetryBandit.setup/1`."
  @spec attach() :: :ok | {:error, :already_exists}
  def attach do
    handler =
      [:bandit, :request, :start]
      |> :telemetry.list_handlers()
      |> Enum.find(&match?({OpentelemetryBandit, _id}, &1.id))

    :ok = :telemetry.detach(handler.id)

    :telemetry.attach_many(
      {__MODULE__, :span},
      @events,
      &__MODULE__.handle_event/4,
      handler.config
    )
  end

  @doc false
  def handle_event([:bandit, :request, suffix] = event, measurements, meta, config) do
    cond do
      suffix == :start and dropped?(meta) ->
        Process.put(@skip, true)

      suffix != :start and Process.delete(@skip) == true ->
        :ok

      true ->
        if suffix == :exception, do: FailedSpan.remember()
        OpentelemetryBandit.handle_request(event, measurements, meta, config)
    end

    :ok
  catch
    _kind, _reason -> :ok
  end

  defp dropped?(%{conn: %{request_path: path}}), do: path in Settings.dropped_paths()
  defp dropped?(_meta), do: false
end
