defmodule AshBrowserTests.Trace do
  @moduledoc """
  Assertions over the spans a test produced.

  Every assertion takes a *selection*: a test key (or any `AshBrowserTests.Backend`
  key), or a list of `AshBrowserTests.Span` already in hand. A key is polled until
  the assertion holds or the timeout passes, so browser spans and late-arriving
  server spans are waited for; a list is checked once. On failure the message prints
  the spans as a tree.

  The pipeline is global, so selection is always by key: nothing here looks at the
  last trace or clears the sink.

  ## Matchers

  `AshBrowserTests.Span.matches?/2` defines them. The named ones below match the
  spans `ash_enterprise_telemetry` and its instrumentation libraries produce:

      assert_chain(key, [browser_event(), handle_event(), ash_action(), query()])

  ## Options

  Every assertion accepts `:timeout` (default 5000), `:backend` and `:poll_ms`.
  """

  alias AshBrowserTests.Backend
  alias AshBrowserTests.Span

  @default_timeout 5_000
  @correlation_id "ash.correlation_id"
  @browser_marker "ui.page.path"

  @type selection :: Backend.key() | [Span.t()]

  # --- Matchers -------------------------------------------------------------------

  @doc "A browser span for one LiveView event. `name:` filters on the event name."
  @spec browser_event(keyword()) :: keyword()
  def browser_event(filters \\ []) do
    [attribute: @browser_marker, attribute: "ui.event.name"] ++
      attribute_filters(filters, name: "ui.event.name")
  end

  @doc "The browser span opened when the LiveView socket connects."
  @spec browser_connect(keyword()) :: keyword()
  def browser_connect(filters \\ []), do: [name: ~r/lv\.connect$/] ++ filters

  @doc "A LiveView connected mount span."
  @spec live_mount(keyword()) :: keyword()
  def live_mount(filters \\ []), do: [name: ~r/\.mount$/] ++ filters

  @doc "A LiveView `handle_event` span."
  @spec handle_event(keyword()) :: keyword()
  def handle_event(filters \\ []), do: [name: ~r/handle_event/] ++ filters

  @doc "An Ash action span. `action:` and `resource:` filter on the Ash attributes."
  @spec ash_action(keyword()) :: keyword()
  def ash_action(filters \\ []) do
    [attribute: "ash.action"] ++
      attribute_filters(filters, action: "ash.action", resource: "ash.resource")
  end

  @doc "An Ecto query span."
  @spec query(keyword()) :: keyword()
  def query(filters \\ []), do: [attribute: "db.system"] ++ filters

  @doc "The producer span written when a job is enqueued."
  @spec job_producer(keyword()) :: keyword()
  def job_producer(filters \\ []), do: [kind: :producer] ++ filters

  @doc "The consumer span of a running job."
  @spec job_consumer(keyword()) :: keyword()
  def job_consumer(filters \\ []), do: [kind: :consumer] ++ filters

  defp attribute_filters(filters, known) do
    Enum.flat_map(filters, fn {key, value} = filter ->
      case Keyword.fetch(known, key) do
        {:ok, attribute} -> [attributes: %{attribute => value}]
        :error -> [filter]
      end
    end)
  end

  # --- Selecting -------------------------------------------------------------------

  @doc "The spans for a selection, without any assertion."
  @spec spans(selection(), keyword()) :: [Span.t()]
  def spans(selection, opts \\ [])
  def spans(spans, _opts) when is_list(spans), do: spans

  def spans(key, opts) do
    case Backend.spans_for(key, Keyword.get(opts, :timeout, 0), opts) do
      {:ok, spans} ->
        spans

      {:error, reason} ->
        raise ExUnit.AssertionError, message: "backend error: #{inspect(reason)}"
    end
  end

  # --- Assertions ------------------------------------------------------------------

  @doc "Asserts some span in the selection matches. Returns it."
  @spec assert_span(selection(), Span.matcher(), keyword()) :: Span.t()
  def assert_span(selection, matcher, opts \\ []) do
    assert_eventually(selection, opts, fn spans ->
      case Enum.find(spans, &Span.matches?(&1, matcher)) do
        nil -> {:error, "no span matches #{inspect(matcher)}"}
        span -> {:ok, span}
      end
    end)
  end

  @doc "Asserts no span in the selection matches."
  @spec refute_span(selection(), Span.matcher(), keyword()) :: :ok
  def refute_span(selection, matcher, opts \\ []) do
    spans = spans(selection, Keyword.put_new(opts, :timeout, 0))

    case Enum.find(spans, &Span.matches?(&1, matcher)) do
      nil ->
        :ok

      span ->
        raise ExUnit.AssertionError,
          message: "expected no span to match, found #{Span.describe(span)}\n\n#{tree(spans)}"
    end
  end

  @doc """
  Asserts one path through the trace visits a span matching each matcher in order.
  Returns the spans on the path.

  By default each step may be any descendant of the previous one (Ash, for example,
  nests spans between an action and its query). `direct: true` requires each step
  to be the immediate child. A step whose parent is missing from the selection,
  which is what a lost context looks like, ends the path.
  """
  @spec assert_chain(selection(), [Span.matcher(), ...], keyword()) :: [Span.t()]
  def assert_chain(selection, [_first, _second | _rest] = matchers, opts \\ []) do
    assert_eventually(selection, opts, fn spans ->
      index = index(spans)
      direct? = Keyword.get(opts, :direct, false)

      case Enum.find_value(spans, &chain_from(index, &1, matchers, direct?)) do
        nil -> {:error, broken_chain_message(index, spans, matchers, direct?)}
        chain -> {:ok, chain}
      end
    end)
  end

  @doc """
  Asserts a span matching `consumer` carries a link to a span matching `producer`,
  in a different trace. Returns `{producer_span, consumer_span}`.
  """
  @spec assert_linked(selection(), Span.matcher(), Span.matcher(), keyword()) ::
          {Span.t(), Span.t()}
  def assert_linked(selection, producer, consumer, opts \\ []) do
    assert_eventually(selection, opts, fn spans ->
      producers = Enum.filter(spans, &Span.matches?(&1, producer))
      consumers = Enum.filter(spans, &Span.matches?(&1, consumer))

      found =
        for c <- consumers,
            p <- producers,
            Enum.any?(c.links, &(&1.trace_id == p.trace_id and &1.span_id == p.span_id)),
            p.trace_id != c.trace_id do
          {p, c}
        end

      case found do
        [pair | _rest] ->
          {:ok, pair}

        [] ->
          {:error,
           """
           no consumer span is linked to a producer span in another trace
             producers: #{describe_all(producers)}
             consumers: #{Enum.map_join(consumers, ", ", &"#{Span.describe(&1)} links=#{inspect(&1.links)}")}
           """}
      end
    end)
  end

  @doc """
  Asserts every span under the span matching `root` carries the same correlation id.
  Returns the id.

  The tree must hold at least two spans (`:min_spans`), as one proves nothing. A
  browser span above the root is outside the tree and is not checked. `:ignore`
  excludes spans by matcher.
  """
  @spec assert_one_correlation(selection(), Span.matcher(), keyword()) :: String.t()
  def assert_one_correlation(selection, root, opts \\ []) do
    min_spans = Keyword.get(opts, :min_spans, 2)
    ignore = Keyword.get(opts, :ignore)

    assert_eventually(selection, opts, fn spans ->
      index = index(spans)

      with %Span{} = root_span <- Enum.find(spans, &Span.matches?(&1, root)),
           tree =
             [root_span | descendants(index, root_span)]
             |> Enum.reject(&(ignore && Span.matches?(&1, ignore))),
           true <- length(tree) >= min_spans do
        correlation_verdict(tree)
      else
        nil -> {:error, "no span matches root #{inspect(root)}"}
        false -> {:error, "the tree under #{inspect(root)} has fewer than #{min_spans} spans"}
      end
    end)
  end

  @doc """
  Asserts an `exception` span event is present. `expected` is the exception's type
  as a string, or a regex over its message, or a keyword list of `:type`, `:message`
  (string or regex) and `:span` (a matcher). Returns the span.
  """
  @spec assert_exception(selection(), String.t() | Regex.t() | keyword(), keyword()) :: Span.t()
  def assert_exception(selection, expected, opts \\ []) do
    criteria =
      case expected do
        type when is_binary(type) -> [type: type]
        %Regex{} = regex -> [message: regex]
        criteria when is_list(criteria) -> criteria
      end

    assert_eventually(selection, opts, fn spans ->
      case Enum.find(spans, &exception?(&1, criteria)) do
        nil -> {:error, "no span has an exception event matching #{inspect(criteria)}"}
        span -> {:ok, span}
      end
    end)
  end

  @doc """
  Asserts every span's parent is in the selection, except spans whose trace root is
  outside it (`:allow_roots`, default `[]`, names matchers for such spans).
  """
  @spec assert_tree_intact(selection(), keyword()) :: :ok
  def assert_tree_intact(selection, opts \\ []) do
    allowed = Keyword.get(opts, :allow_roots, [])

    assert_eventually(selection, opts, fn spans ->
      index = index(spans)

      orphans =
        Enum.filter(spans, fn span ->
          span.parent_span_id != nil and not parent_present?(index, span) and
            not Enum.any?(allowed, &Span.matches?(span, &1))
        end)

      case {spans, orphans} do
        {[], _orphans} -> {:error, "no spans for the selection"}
        {_spans, []} -> {:ok, :ok}
        {_spans, orphans} -> {:error, "spans whose parent is missing: #{describe_all(orphans)}"}
      end
    end)
  end

  # --- Internals -----------------------------------------------------------------

  defp assert_eventually(selection, _opts, check) when is_list(selection) do
    case check.(selection) do
      {:ok, result} -> result
      {:error, message} -> fail(message, selection)
    end
  end

  defp assert_eventually(key, opts, check) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    deadline = System.monotonic_time(:millisecond) + timeout
    poll(key, opts, check, deadline)
  end

  defp poll(key, opts, check, deadline) do
    spans = spans(key, Keyword.put(opts, :timeout, 0))

    case check.(spans) do
      {:ok, result} ->
        result

      {:error, message} ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(Keyword.get(opts, :poll_ms, 20))
          poll(key, opts, check, deadline)
        else
          fail(message, spans)
        end
    end
  end

  defp fail(message, spans) do
    raise ExUnit.AssertionError, message: "#{message}\n\nspans seen:\n#{tree(spans)}"
  end

  defp correlation_verdict(tree) do
    case tree |> Enum.map(&Map.get(&1.attributes, @correlation_id)) |> Enum.uniq() do
      [id] when is_binary(id) ->
        {:ok, id}

      [nil] ->
        {:error, "no span in the tree carries #{@correlation_id}"}

      ids ->
        {:error,
         "expected one #{@correlation_id} across the tree, found #{inspect(ids)}: #{describe_all(tree)}"}
    end
  end

  defp exception?(span, criteria) do
    matcher = Keyword.get(criteria, :span)

    (matcher == nil or Span.matches?(span, matcher)) and
      Enum.any?(span.events, fn event ->
        event.name == "exception" and event_matches?(event, criteria)
      end)
  end

  defp event_matches?(event, criteria) do
    attribute_matches?(Keyword.get(criteria, :type), event.attributes["exception.type"]) and
      attribute_matches?(Keyword.get(criteria, :message), event.attributes["exception.message"])
  end

  defp attribute_matches?(nil, _actual), do: true
  defp attribute_matches?(_expected, nil), do: false
  defp attribute_matches?(%Regex{} = regex, actual), do: Regex.match?(regex, to_string(actual))
  defp attribute_matches?(expected, actual), do: to_string(actual) == to_string(expected)

  # Parents are keyed by trace as well: a span id means nothing across traces.
  defp index(spans) do
    %{
      children: Enum.group_by(spans, &{&1.trace_id, &1.parent_span_id}),
      by_id: Map.new(spans, &{{&1.trace_id, &1.span_id}, &1})
    }
  end

  defp children(index, span), do: Map.get(index.children, {span.trace_id, span.span_id}, [])

  defp descendants(index, span) do
    children(index, span) |> Enum.flat_map(&[&1 | descendants(index, &1)])
  end

  defp parent_present?(index, span) do
    Map.has_key?(index.by_id, {span.trace_id, span.parent_span_id})
  end

  defp chain_from(index, span, [matcher | rest], direct?) do
    if Span.matches?(span, matcher) do
      continue_chain(index, span, rest, direct?)
    end
  end

  defp continue_chain(_index, span, [], _direct?), do: [span]

  defp continue_chain(index, span, rest, direct?) do
    candidates = if direct?, do: children(index, span), else: descendants(index, span)

    Enum.find_value(candidates, fn candidate ->
      case chain_from(index, candidate, rest, direct?) do
        nil -> nil
        path -> [span | path]
      end
    end)
  end

  defp broken_chain_message(index, spans, matchers, direct?) do
    reached =
      matchers
      |> Enum.scan([], fn matcher, prefix -> prefix ++ [matcher] end)
      |> Enum.take_while(fn prefix ->
        Enum.any?(spans, &chain_from(index, &1, prefix, direct?))
      end)
      |> length()

    "no chain of #{length(matchers)} spans; reached step #{reached}, " <>
      "then nothing matched #{inspect(Enum.at(matchers, reached))}"
  end

  defp describe_all(spans), do: Enum.map_join(spans, ", ", &Span.describe/1)

  @max_tree_lines 200

  @doc false
  def tree([]), do: "  (none)"

  def tree(spans) do
    index = index(spans)
    roots = Enum.reject(spans, &(&1.parent_span_id != nil and parent_present?(index, &1)))

    lines =
      Enum.flat_map(roots, fn root ->
        [root_line(root, index) | child_lines(index, root, 2)]
      end)

    lines |> Enum.take(@max_tree_lines) |> Enum.join("\n")
  end

  defp root_line(span, index) do
    marker = if span.parent_span_id && !parent_present?(index, span), do: " (parent missing)"
    "  #{Span.describe(span)}#{marker}"
  end

  defp child_lines(index, span, depth) do
    children(index, span)
    |> Enum.flat_map(fn child ->
      [
        "#{String.duplicate("  ", depth)}#{Span.describe(child)}"
        | child_lines(index, child, depth + 1)
      ]
    end)
  end
end
