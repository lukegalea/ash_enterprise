defmodule AshBrowserTests.Span do
  @moduledoc """
  One span, in the shape every `AshBrowserTests.Backend` returns.

  Ids are lower-case hex (32 characters for a trace, 16 for a span), so a span from
  the in-VM sink and the same span read back from a real backend compare equal.
  `attributes` has string keys.

  `matches?/2` is the matcher used by every assertion in `AshBrowserTests.Trace`:

    * a string matches the name exactly
    * a regex matches the name
    * a one-argument function is a predicate
    * a keyword list (or map) requires each of `:name`, `:kind`, `:status`,
      `:attributes`, `:attribute` and `:has_event`; an attribute value may be a
      regex or `:present`
  """

  @enforce_keys [:trace_id, :span_id, :name]
  defstruct [
    :trace_id,
    :span_id,
    :parent_span_id,
    :name,
    :status_message,
    :start_ns,
    :end_ns,
    kind: :internal,
    status: :unset,
    attributes: %{},
    events: [],
    links: [],
    source: nil
  ]

  @type event :: %{name: String.t(), attributes: map()}
  @type link :: %{trace_id: String.t(), span_id: String.t()}

  @type t :: %__MODULE__{
          trace_id: String.t(),
          span_id: String.t(),
          parent_span_id: String.t() | nil,
          name: String.t(),
          status_message: String.t() | nil,
          start_ns: integer() | nil,
          end_ns: integer() | nil,
          kind: atom(),
          status: :ok | :error | :unset,
          attributes: map(),
          events: [event()],
          links: [link()],
          source: atom() | nil
        }

  @type matcher ::
          String.t()
          | Regex.t()
          | (t() -> boolean())
          | keyword()
          | map()

  @doc "A hex id from an integer, or a hex string, or nil for no id."
  @spec hex(term(), pos_integer()) :: String.t() | nil
  def hex(nil, _width), do: nil
  def hex(:undefined, _width), do: nil
  def hex(0, _width), do: nil
  def hex("", _width), do: nil

  def hex(id, width) when is_integer(id) do
    id |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(width, "0")
  end

  def hex(id, _width) when is_binary(id), do: String.downcase(id)

  @doc "Whether `span` satisfies `matcher`. See the moduledoc."
  @spec matches?(t(), matcher()) :: boolean()
  def matches?(%__MODULE__{} = span, name) when is_binary(name), do: span.name == name
  def matches?(%__MODULE__{} = span, %Regex{} = regex), do: Regex.match?(regex, span.name)
  def matches?(%__MODULE__{} = span, fun) when is_function(fun, 1), do: fun.(span) == true

  def matches?(%__MODULE__{} = span, criteria) when is_list(criteria) or is_map(criteria) do
    Enum.all?(criteria, &criterion?(span, &1))
  end

  defp criterion?(span, {:name, expected}), do: value_matches?(span.name, expected)
  defp criterion?(span, {:kind, expected}), do: span.kind == expected
  defp criterion?(span, {:status, expected}), do: span.status == expected

  defp criterion?(span, {:attributes, expected}) do
    Enum.all?(expected, fn {key, value} ->
      value_matches?(Map.get(span.attributes, to_string(key)), value)
    end)
  end

  defp criterion?(span, {:attribute, key}), do: Map.has_key?(span.attributes, to_string(key))

  defp criterion?(span, {:has_event, name}) do
    Enum.any?(span.events, &(&1.name == name))
  end

  defp criterion?(_span, {key, _expected}) do
    raise ArgumentError, "unknown span matcher key: #{inspect(key)}"
  end

  defp value_matches?(nil, _expected), do: false
  defp value_matches?(_actual, :present), do: true
  defp value_matches?(actual, %Regex{} = regex), do: Regex.match?(regex, to_string(actual))
  defp value_matches?(actual, expected), do: to_string(actual) == to_string(expected)

  @doc "A short description for a failure message."
  @spec describe(t()) :: String.t()
  def describe(%__MODULE__{} = span) do
    "#{span.name} [#{span.span_id}] #{span.status}"
  end
end
