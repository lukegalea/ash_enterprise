defmodule AshEnterprise.Telemetry.GenAI.ContentFreeAdapter do
  @moduledoc """
  The tracer req_llm's bridge (`ReqLLM.OpenTelemetry`) writes model call spans through
  (`ReqLLM.OpenTelemetry.Adapter`): its default, `ReqLLM.OpenTelemetry.OTelAdapter`,
  with what can carry content taken out on the way.

  `content: :none` keeps message payloads off a span, but a failed call still reaches
  it with the provider's error text twice: as the span's status description and as the
  `exception.message` of its exception event. A provider's error can quote the request
  back (the prompt, or what a person wrote), and `AshEnterprise.AI.ModelCall` refuses
  to store an error message for that reason. Here:

    * an error status says which error by its class, the `error.type` the bridge set on
      the span, or by a description that is one of the bridge's own fixed ones
      (`HTTP <status>`, `request failed`, a builtin tool call `failed` or
      `incomplete`); any other description is replaced by the class, or dropped;
    * an exception event keeps `exception.type` and loses `exception.message` and
      `exception.stacktrace`;
    * the attributes the GenAI conventions mark as content (`@content`) are dropped
      from every span and event, whatever the bridge's content mode.

  Everything else is the default adapter's.
  """

  @behaviour ReqLLM.OpenTelemetry.Adapter

  alias ReqLLM.OpenTelemetry.OTelAdapter

  # What the GenAI semantic conventions (v1.41.0) mark Opt-In: content.
  @content [
    "gen_ai.input.messages",
    "gen_ai.output.messages",
    "gen_ai.system_instructions",
    "gen_ai.tool.definitions",
    "gen_ai.tool.call.arguments",
    "gen_ai.tool.call.result"
  ]

  # The exception event attributes that are the error's own text.
  @exception_text ["exception.message", "exception.stacktrace"]

  # The bridge's own status descriptions: fixed text, never the provider's.
  @fixed ~r/\A(HTTP \d{3}|request failed|builtin tool call (failed|incomplete))\z/

  @impl true
  defdelegate available?(), to: OTelAdapter

  @impl true
  def start_span(name, attributes, config),
    do: OTelAdapter.start_span(name, content_free(attributes), config)

  @impl true
  def set_attributes(span, attributes, config) do
    attributes = content_free(attributes)
    remember_class(span, attributes)
    OTelAdapter.set_attributes(span, attributes, config)
  end

  @impl true
  def add_event(span, name, attributes, config) do
    attributes = content_free(attributes)

    attributes =
      if to_string(name) == "exception",
        do: Map.reject(attributes, fn {key, _value} -> to_string(key) in @exception_text end),
        else: attributes

    OTelAdapter.add_event(span, name, attributes, config)
  end

  @impl true
  def set_status(span, :error, message, config),
    do: OTelAdapter.set_status(span, :error, description(span, message), config)

  def set_status(span, kind, message, config),
    do: OTelAdapter.set_status(span, kind, message, config)

  @impl true
  def end_span(span, config) do
    forget_class(span)
    OTelAdapter.end_span(span, config)
  end

  @impl true
  defdelegate metrics_available?(), to: OTelAdapter

  @impl true
  defdelegate record_histogram(record, config), to: OTelAdapter

  @impl true
  def start_child_span(parent, name, attributes, opts, config),
    do: OTelAdapter.start_child_span(parent, name, content_free(attributes), opts, config)

  @impl true
  def end_span_at(span, end_time, config) do
    forget_class(span)
    OTelAdapter.end_span_at(span, end_time, config)
  end

  @doc false
  # The description an error status is given: a fixed one of the bridge's as it is,
  # anything else the span's error class, or nothing.
  @spec description(term(), String.t() | nil) :: String.t() | nil
  def description(span, message) do
    if is_binary(message) and Regex.match?(@fixed, message),
      do: message,
      else: Process.get(class_key(span))
  end

  defp content_free(attributes) when is_map(attributes),
    do: Map.reject(attributes, fn {key, _value} -> to_string(key) in @content end)

  defp content_free(attributes), do: attributes

  # The bridge sets a terminal span's attributes, `error.type` among them, before its
  # status, in the same call (`ReqLLM.OpenTelemetry.Translator.apply_terminal/4`).
  defp remember_class(span, attributes) when is_map(attributes) do
    case Enum.find(attributes, fn {key, _value} -> to_string(key) == "error.type" end) do
      {_key, class} when is_binary(class) -> Process.put(class_key(span), class)
      _none -> :ok
    end
  end

  defp remember_class(_span, _attributes), do: :ok

  defp forget_class(span), do: Process.delete(class_key(span))

  defp class_key(span), do: {__MODULE__, :error_type, span}
end
