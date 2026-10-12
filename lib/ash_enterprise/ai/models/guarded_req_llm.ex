defmodule AshEnterprise.AI.Models.GuardedReqLLM do
  @moduledoc """
  The ReqLLM module AshAi calls through: `req_llm: #{inspect(__MODULE__)}` on
  a `prompt/2` action or an `AshAi.ToolLoop` run.

  Each function classifies the model it is handed (`AshEnterprise.AI.Models.resolve/1`),
  applies the ADR 0042 flow guard, adds the in-zone profile's transport options
  (host, key, reasoning effort), calls the real ReqLLM and records the call.

  The caller's name rides in the options as `caller: "…"` and is removed
  before ReqLLM sees them (ReqLLM rejects options it does not know). A call
  without one is recorded as `"unnamed"` — still guarded, still recorded.

  `downstream: Module` substitutes the module that actually makes the request.
  Tests use it; nothing else should.
  """

  alias AshEnterprise.AI.Models
  alias ReqLLM.StreamResponse
  alias ReqLLM.StreamResponse.MetadataHandle

  @doc "As `ReqLLM.generate_object/4`, guarded and recorded."
  def generate_object(model, context, schema, opts \\ []) do
    {caller, downstream, opts} = split(opts)

    Models.call(Models.resolve(model), caller, :generate_object, opts, fn call_opts ->
      downstream.generate_object(model, context, schema, call_opts)
    end)
  end

  @doc "As `ReqLLM.generate_text/3`, guarded and recorded."
  def generate_text(model, context, opts \\ []) do
    {caller, downstream, opts} = split(opts)

    Models.call(Models.resolve(model), caller, :generate_text, opts, fn call_opts ->
      downstream.generate_text(model, context, call_opts)
    end)
  end

  @doc """
  As `ReqLLM.stream_text/3`, guarded. A stream's usage exists only once it has
  been read, so its record is written when the reader finishes (or abandons)
  it, from the reading process; a stream that fails to open is recorded at
  once.
  """
  def stream_text(model, context, opts \\ []) do
    {caller, downstream, opts} = split(opts)
    target = Models.resolve(model)
    :ok = Models.guard!(target, caller, :stream_text)
    started = System.monotonic_time()

    case downstream.stream_text(model, context, Models.transport_opts(target, opts)) do
      {:ok, %StreamResponse{} = response} ->
        {:ok, %{response | stream: recorded(response, target, caller, started)}}

      {:error, reason} = error ->
        Models.record(
          target,
          caller,
          :stream_text,
          :error,
          nil,
          Models.elapsed_ms(started),
          Models.error_class(reason)
        )

        error
    end
  end

  # `last` runs only when the stream ends normally; `after` runs however it
  # ends -- read to the end, abandoned by the reader, or failed mid-stream (a
  # transport error surfaces as a raise while the reader enumerates). Only the
  # first is a call that answered.
  defp recorded(%StreamResponse{stream: stream} = response, target, caller, started) do
    Stream.transform(
      stream,
      fn -> :reading end,
      fn chunk, acc -> {[chunk], acc} end,
      fn _acc -> {[], :finished} end,
      fn
        :finished ->
          record_stream(target, caller, :ok, usage(response), started, nil)

        :reading ->
          record_stream(target, caller, :error, nil, started, "incomplete_stream")
      end
    )
  end

  defp record_stream(target, caller, outcome, usage, started, error_class) do
    Models.record(
      target,
      caller,
      :stream_text,
      outcome,
      usage,
      Models.elapsed_ms(started),
      error_class
    )
  end

  # The metadata handle may already be stopped by the reader (ToolLoop closes
  # the response when it is done): then there is no usage to report, which is
  # recorded as such rather than failing the call.
  defp usage(%StreamResponse{metadata_handle: handle}) when is_pid(handle) do
    case MetadataHandle.await(handle, 5_000) do
      %{usage: usage} when is_map(usage) -> usage
      _ -> nil
    end
  catch
    _kind, _reason -> nil
  end

  defp usage(_response), do: nil

  defp split(opts) do
    {caller, opts} = Keyword.pop(opts, :caller, "unnamed")
    {downstream, opts} = Keyword.pop(opts, :downstream, ReqLLM)
    {to_string(caller), downstream, opts}
  end
end
