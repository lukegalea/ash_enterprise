defmodule AshEnterprise.Telemetry.OtlpIngest.Tasks do
  @moduledoc false

  # Forwarding runs in a supervised task, so a slow collector cannot hold a request
  # open. max_children bounds it: when the collector is slower than the browser, the
  # excess batches are dropped rather than queued without limit.

  @supervisor __MODULE__

  @max_children 16
  @timeout_ms 5_000

  @spec child_spec(term()) :: Supervisor.child_spec()
  def child_spec(_arg) do
    Task.Supervisor.child_spec(name: @supervisor, max_children: @max_children)
  end

  @spec forward(String.t(), map(), keyword()) :: :ok | {:error, term()}
  def forward(url, payload, req_options) do
    fun = fn -> post(url, payload, req_options) end

    case Task.Supervisor.start_child(@supervisor, fun) do
      {:ok, _pid} -> :ok
      {:ok, _pid, _info} -> :ok
      :ignore -> {:error, :ignored}
      {:error, reason} -> {:error, reason}
    end
  catch
    :exit, reason -> {:error, reason}
  end

  defp post(url, payload, req_options) do
    [url: url, json: payload, retry: false, receive_timeout: @timeout_ms]
    |> Keyword.merge(req_options)
    |> Req.post()
  end
end
