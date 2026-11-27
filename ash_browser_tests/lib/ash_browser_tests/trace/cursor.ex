defmodule AshBrowserTests.Trace.Cursor do
  @moduledoc """
  A selection narrowed to the spans of one step of a multi-step test: the spans
  that started at or after the instant the step began, and before the next step
  began.

      step_one = Trace.cursor(key, "01-open")
      conn = visit(conn, "/orders")
      Trace.assert_chain(step_one, [live_mount(), query()])

      step_two = Trace.cursor(key, "02-approve")
      conn = click_button(conn, "Approve")
      Trace.assert_chain(step_two, [handle_event(), ash_action(action: :approve)])

  A test key selects every span of the test, so without a cursor the second
  assertion also sees the first step's spans, and a span lost in step two is
  masked by a matching one from step one. A cursor is taken before the step acts
  and every assertion about that step is made against it.

  ## The window

  `since` is `System.monotonic_time/0` in native units, the clock OpenTelemetry
  stamps span start times with (`opentelemetry:timestamp/0`); the trace sink
  converts spans ingested from the browser onto the same clock. `until` is open
  (`nil`) while the step runs, which is when its assertions are made: nothing of
  the next step has started yet. `close/2` sets it to the instant the next step
  began, giving the window `[since, until)` a run records afterwards
  (`window/2`).

  A span whose start time is unknown is never selected: nothing proves it belongs
  to the step. A span that starts inside the window but belongs to an earlier
  step (a job that step enqueued, finishing late) is selected. Assertions are
  existential, so such a span cannot fail one; it can only satisfy one it should
  not, and only when it has the same shape.

  `label` names the step in failure messages.
  """

  alias AshBrowserTests.Backend
  alias AshBrowserTests.Span

  @enforce_keys [:key, :since]
  defstruct [:key, :since, :until, :label]

  @type t :: %__MODULE__{
          key: Backend.key(),
          since: integer(),
          until: integer() | nil,
          label: term()
        }

  @doc "A cursor for `key`, open from this instant."
  @spec new(Backend.key(), term()) :: t()
  def new(key, label \\ nil) do
    %__MODULE__{key: key, since: System.monotonic_time(), label: label}
  end

  @doc "Closes the window at `at` (default: now), the instant the next step began."
  @spec close(t(), integer()) :: t()
  def close(%__MODULE__{} = cursor, at \\ System.monotonic_time()), do: %{cursor | until: at}

  @doc "The spans in `spans` that started inside the cursor's window."
  @spec select(t(), [Span.t()]) :: [Span.t()]
  def select(%__MODULE__{} = cursor, spans), do: Enum.filter(spans, &inside?(cursor, &1))

  @doc """
  The window as positions in a test's span stream, `%{from:, to:}`: the stream is
  every span in `spans` with a start time, in start order, and the window is
  `[from, to)` of it. An open cursor's window runs to the end of the stream.
  """
  @spec window(t(), [Span.t()]) :: %{from: non_neg_integer(), to: non_neg_integer()}
  def window(%__MODULE__{since: since, until: until}, spans) do
    starts = for %Span{start_ns: start} <- spans, is_integer(start), do: start

    %{
      from: Enum.count(starts, &(&1 < since)),
      to: if(until, do: Enum.count(starts, &(&1 < until)), else: length(starts))
    }
  end

  defp inside?(%__MODULE__{since: since, until: until}, %Span{start_ns: start}) do
    is_integer(start) and start >= since and (until == nil or start < until)
  end
end
