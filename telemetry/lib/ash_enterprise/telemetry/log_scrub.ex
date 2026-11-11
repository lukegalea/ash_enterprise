defmodule AshEnterprise.Telemetry.LogScrub do
  @moduledoc false

  # The OTLP log handler's filter: what keeps runtime values out of exported log
  # records, on the same rule as spans and Sentry events. A crash or error report
  # loses its arguments, last message, state and exit-reason data; stack frames keep
  # their arity, never their arguments; metadata keeps scalars only.
  #
  # A crash report is rebuilt from its structured fields (the original report, or the
  # `crash_reason` metadata the Elixir translator and Bandit attach), so what is
  # exported is assembled from sanitized parts rather than cut out of formatted
  # text. Text that arrives already formatted, such as `Exception.format_exit/1`
  # output logged by a library, is scrubbed line by line as a second line of defence.
  #
  # A filter that fails drops the event: an unscrubbed record must not be exported.

  alias AshEnterprise.Telemetry.Sanitize

  @filtered "[Filtered]"
  @max_body_bytes 16_384
  @max_metadata_bytes 1_024
  @drop {__MODULE__, :drop}

  # Read by the handler itself; `:gl`, `:time` and `:report_cb` are never exported.
  @handler_keys [:time, :gl, :report_cb, :otel_scope]

  # Exceptions whose message prints the value they were raised over.
  @value_exceptions ~w(MatchError CaseClauseError WithClauseError TryClauseError KeyError
    BadMapError BadStructError BadBooleanError BadFunctionError BadArityError ErlangError
    Protocol.UndefinedError)

  # From here on, a translated crash report prints the process's data.
  @dump ~r/\A\s*(?:Last message|State: |Function: |Args: |Queue: |Postponed: |Process Label: |Client \S+ is alive)/
  @arguments ~r/\A(\s*)The following arguments were given to /
  @banner ~r/\A(\s*\*\* \()([A-Za-z.]+)\) ?(.*)\z/
  @exit_kinds ~w(exit stop EXIT throw)
  @safe_exit ~r/\A(?::?[a-z_][A-Za-z0-9_.]*|an exception was raised:)\z/
  @frame_call ~r/\A(\s+(?:\([^)]*\) )?(?:\S+\.(?:ex|exs|erl)(?::\d+)?|nofile): )([^\s(]+)\(.*\)\z/
  @anonymous_call ~r/\A(\s+(?:\([^)]*\) )?(?:\S+\.(?:ex|exs|erl)(?::\d+)?|nofile): anonymous fn)\(.*\)( in \S+)\z/
  @exited_in ~r/\A(\s*exited in: )([^\s(]+)\(.*\z/
  @frame ~r/\A\s+(?:\([^)]*\) )?(?:\S+\.(?:ex|exs|erl)(?::\d+)?|nofile): \S/
  @url_query ~r{(https?://[^\s?#"']+)\?[^\s"'#]*}
  @header ~r/\A(?:GenServer|Task|Process|:gen_statem|:gen_event handler|Child|Children) [^\n]{0,240}\z/

  # `extra` may name metadata keys to keep as they are (`%{keep: [:crash_reason]}`), for
  # a handler that reports from them.
  @spec filter(:logger.log_event(), term()) :: :logger.log_event() | :stop
  def filter(%{msg: msg, meta: meta} = event, extra) when is_map(meta) do
    keep = if is_map(extra), do: List.wrap(Map.get(extra, :keep)), else: []
    %{event | msg: message(msg, Map.get(meta, :crash_reason)), meta: metadata(meta, keep)}
  catch
    _kind, _reason -> :stop
  end

  def filter(_event, _extra), do: :stop

  # Already formatted text, scrubbed line by line.
  @spec text(binary()) :: binary()
  def text(text) when is_binary(text), do: finish(text)

  ## Message

  defp message({:report, report} = msg, crash) do
    case report_body(fields(report), crash) do
      nil -> msg
      body -> {:string, body}
    end
  end

  defp message({:string, chardata}, crash), do: {:string, string_body(to_text(chardata), crash)}

  defp message({format, args}, crash) when is_list(args),
    do: {:string, format_body(format, args, crash)}

  defp message(_other, _crash), do: {:string, @filtered}

  defp fields(report) when is_map(report), do: report

  defp fields(report) when is_list(report) do
    if Keyword.keyword?(report), do: Map.new(report), else: %{}
  end

  defp fields(_report), do: %{}

  # `nil` keeps a host's own structured report as it is.
  defp report_body(%{label: {:error_logger, _}, format: format, args: args}, crash)
       when is_list(args),
       do: format_body(format, args, crash)

  defp report_body(fields, crash) do
    case describe(Map.get(fields, :label), fields) do
      nil when is_nil(crash) -> nil
      nil -> finish(crash_text(crash))
      text -> finish(text)
    end
  end

  defp describe({:proc_lib, :crash}, %{report: [info | _]}) when is_list(info) do
    {class, reason, stack} =
      case Keyword.get(info, :error_info) do
        {class, reason, stack} -> {class, reason, stack}
        _other -> {:exit, :unknown, []}
      end

    [
      "Process ",
      process_name(info[:pid], info[:registered_name]),
      " terminating\n",
      reason_text(class, reason, stack)
    ]
  end

  defp describe({:supervisor, :progress}, %{report: data}) when is_list(data) do
    started = keyword(data[:started])
    ["Child ", child_id(started[:id]), "of Supervisor ", name(data[:supervisor]), " started"]
  end

  defp describe({:supervisor, context}, %{report: data}) when is_list(data) do
    offender =
      case data[:offender] do
        [first | _] when is_list(first) -> first
        offender -> keyword(offender)
      end

    [
      "Child ",
      child_id(offender[:id]),
      "of Supervisor ",
      name(data[:supervisor]),
      " ",
      supervisor_context(context),
      "\n",
      reason_text(:exit, data[:reason], [])
    ]
  end

  defp describe({Task.Supervisor, :terminating}, %{report: data}) when is_map(data) do
    [
      "Task ",
      name(data[:name]),
      " started from ",
      name(data[:starter]),
      " terminating\n",
      reason_text(:exit, data[:reason], [])
    ]
  end

  defp describe({GenServer, :no_handle_info}, %{report: data}) when is_map(data) do
    [name(data[:name]), " ", name(data[:module]), " received unexpected message in handle_info/2"]
  end

  defp describe({:application_controller, :progress}, %{report: data}) when is_list(data),
    do: ["Application ", name(data[:application]), " started"]

  defp describe({:application_controller, :exit}, %{report: data}) when is_list(data),
    do: [
      "Application ",
      name(data[:application]),
      " exited: ",
      Sanitize.reason_label(data[:exited])
    ]

  defp describe({:gen_server, :terminate}, fields),
    do: [
      "GenServer ",
      name(fields[:name]),
      " terminating\n",
      reason_text(:exit, fields[:reason], [])
    ]

  defp describe({:gen_statem, :terminate}, fields) do
    reason =
      case fields[:reason] do
        {class, reason, stack} when class in [:error, :exit, :throw] and is_list(stack) ->
          reason_text(class, reason, stack)

        reason ->
          reason_text(:exit, reason, [])
      end

    [":gen_statem ", name(fields[:name]), " terminating\n", reason]
  end

  defp describe({:gen_event, :terminate}, fields) do
    [
      ":gen_event handler ",
      name(fields[:handler]),
      " installed in ",
      name(fields[:name]),
      " terminating\n",
      reason_text(:exit, fields[:reason], [])
    ]
  end

  defp describe(nil, _fields), do: nil

  defp describe(label, fields) do
    case Map.fetch(fields, :reason) do
      {:ok, reason} -> [label_text(label), "\n", reason_text(:exit, reason, [])]
      :error -> label_text(label)
    end
  end

  defp label_text(label) when is_atom(label), do: inspect(label)

  defp label_text(label) when is_tuple(label) do
    if label |> Tuple.to_list() |> Enum.all?(&is_atom/1), do: inspect(label), else: "report"
  end

  defp label_text(_label), do: "report"

  defp supervisor_context(:child_terminated), do: "terminated"
  defp supervisor_context(:start_error), do: "failed to start"
  defp supervisor_context(:shutdown_error), do: "shut down abnormally"
  defp supervisor_context(:shutdown), do: "caused shutdown"
  defp supervisor_context(context) when is_atom(context), do: inspect(context)
  defp supervisor_context(_context), do: "reported"

  defp keyword(value) when is_list(value) do
    if Keyword.keyword?(value), do: value, else: []
  end

  defp keyword(_value), do: []

  defp child_id(id) when id in [nil, :undefined], do: ""
  defp child_id(id), do: [name(id), " "]

  defp process_name(pid, name) when is_atom(name) and name not in [nil, []],
    do: [inspect(name), " (", name(pid), ")"]

  defp process_name(pid, _name), do: name(pid)

  # A process, module or registered name; anything else could be data.
  defp name(name) when is_atom(name), do: inspect(name)
  defp name(name) when is_pid(name) or is_port(name) or is_reference(name), do: inspect(name)
  defp name({scope, name}) when scope in [:local, :global] and is_atom(name), do: inspect(name)

  defp name({pid, module}) when is_pid(pid) and is_atom(module),
    do: [inspect(pid), " (", inspect(module), ")"]

  defp name({:via, module, _name}) when is_atom(module),
    do: ["{:via, ", inspect(module), ", ...}"]

  defp name(_name), do: @filtered

  ## Reasons

  # Translated reasons carry their stacktrace: `{reason, stacktrace}`.
  defp crash_text({reason, stack}) when is_list(stack), do: reason_text(:error, reason, stack)
  defp crash_text(reason), do: reason_text(:exit, reason, [])

  defp reason_text(:exit, {reason, stack}, []) when is_list(stack) and stack != [] do
    if stacktrace?(stack),
      do: reason_text(:error, reason, stack),
      else: ["** (exit) ", Sanitize.reason_label({reason, stack})]
  end

  defp reason_text(:throw, _value, stack), do: ["** (throw) ", @filtered, stack_text(stack)]

  defp reason_text(kind, reason, stack) do
    cond do
      is_exception(reason) ->
        [banner(reason), stack_text(stack)]

      kind == :error and stack != [] ->
        [banner(Exception.normalize(:error, reason, stack)), stack_text(stack)]

      true ->
        ["** (exit) ", exit_label(reason), stack_text(stack)]
    end
  end

  # An exit from a call names the call, never its arguments.
  defp exit_label({reason, {module, function, args}})
       when is_atom(module) and is_atom(function) and is_list(args) do
    [
      crash_text(reason),
      "\n    (in ",
      inspect(module),
      ".",
      Atom.to_string(function),
      "/",
      Integer.to_string(length(args)),
      ")"
    ]
  end

  defp exit_label(reason), do: Sanitize.reason_label(reason)

  defp banner(exception) do
    exception = Sanitize.exception(exception)

    message =
      try do
        Exception.message(exception)
      catch
        _kind, _reason -> "[message unavailable]"
      end

    ["** (", inspect(exception.__struct__), ") ", message]
  end

  defp stack_text([]), do: []

  defp stack_text(stack) do
    if stacktrace?(stack) do
      [
        "\n",
        stack |> Sanitize.stacktrace() |> Exception.format_stacktrace() |> String.trim_trailing()
      ]
    else
      []
    end
  catch
    _kind, _reason -> []
  end

  defp stacktrace?(stack) when is_list(stack) and stack != [] do
    Enum.all?(stack, fn
      {module, function, args, location}
      when is_atom(module) and is_atom(function) and (is_list(args) or is_integer(args)) and
             is_list(location) ->
        true

      {fun, args, location}
      when is_function(fun) and is_list(location) and
             (is_list(args) or is_integer(args)) ->
        true

      _other ->
        false
    end)
  end

  defp stacktrace?(_stack), do: false

  ## Formatted messages

  defp string_body(text, nil), do: finish(text)
  defp string_body(text, crash), do: finish([header(text), crash_text(crash)])

  defp header(text) do
    [first | _] = String.split(text, "\n", parts: 2)
    if Regex.match?(@header, first), do: [first, "\n"], else: []
  end

  # A format's arguments are runtime values: only names, numbers and frames survive.
  defp format_body(format, args, crash) do
    text =
      try do
        format |> :io_lib.format(Enum.map(args, &format_argument/1)) |> to_text()
      catch
        _kind, _reason -> "[unformattable] " <> to_text(format)
      end

    string_body(text, crash)
  end

  defp format_argument(arg)
       when is_atom(arg) or is_number(arg) or is_pid(arg) or is_port(arg) or is_reference(arg),
       do: arg

  defp format_argument(arg) do
    if stacktrace?(arg), do: Sanitize.stacktrace(arg), else: :"[Filtered]"
  end

  defp to_text(chardata) when is_binary(chardata), do: chardata
  defp to_text(chardata) when is_atom(chardata), do: Atom.to_string(chardata)

  defp to_text(chardata) do
    case :unicode.characters_to_binary(chardata) do
      text when is_binary(text) -> text
      {_problem, text, _rest} -> text
    end
  end

  defp finish(iodata) do
    iodata
    |> to_text()
    |> String.split("\n")
    |> scrub_lines(:keep, [])
    |> Enum.reverse()
    |> Enum.join("\n")
    |> then(&Regex.replace(@url_query, &1, "\\1?#{@filtered}"))
    |> Sanitize.truncate(@max_body_bytes)
  end

  defp scrub_lines([], _state, acc), do: acc

  defp scrub_lines([line | rest], {:skip_arguments, indent} = state, acc) do
    if String.trim(line) == "" or indent(line) > indent,
      do: scrub_lines(rest, state, acc),
      else: scrub_lines([line | rest], :keep, acc)
  end

  defp scrub_lines([line | rest], :skip_value, acc) do
    if Regex.match?(@frame, line) or Regex.match?(@banner, line),
      do: scrub_lines([line | rest], :keep, acc),
      else: scrub_lines(rest, :skip_value, acc)
  end

  defp scrub_lines([line | rest], :keep, acc) do
    cond do
      Regex.match?(@dump, line) ->
        acc

      match = Regex.run(@arguments, line) ->
        [_all, indent] = match
        scrub_lines(rest, {:skip_arguments, String.length(indent)}, acc)

      match = Regex.run(@banner, line) ->
        {line, state} = banner_line(match)
        scrub_lines(rest, state, [line | acc])

      true ->
        scrub_lines(rest, :keep, [call_line(line) | acc])
    end
  end

  defp banner_line([line, prefix, kind, rest]) do
    cond do
      kind in @value_exceptions ->
        {"#{prefix}#{kind}) #{@filtered}", :skip_value}

      kind in @exit_kinds and not Regex.match?(@safe_exit, rest) ->
        {"#{prefix}#{kind}) #{@filtered}", :skip_value}

      true ->
        {line, :keep}
    end
  end

  defp call_line(line) do
    cond do
      Regex.match?(@anonymous_call, line) -> Regex.replace(@anonymous_call, line, "\\1/?\\2")
      Regex.match?(@frame_call, line) -> Regex.replace(@frame_call, line, "\\1\\2/?")
      Regex.match?(@exited_in, line) -> Regex.replace(@exited_in, line, "\\1\\2/?")
      true -> line
    end
  end

  defp indent(line), do: byte_size(line) - byte_size(String.trim_leading(line))

  ## Metadata

  defp metadata(meta, keep) do
    for {key, value} <- meta,
        (kept = if(key in keep, do: value, else: metadata_value(key, value))) != @drop,
        into: %{} do
      {key, kept}
    end
  end

  defp metadata_value(key, value) when key in @handler_keys, do: value
  defp metadata_value(:crash_reason, _value), do: @drop

  defp metadata_value(_key, value) when is_binary(value),
    do: Sanitize.truncate(value, @max_metadata_bytes)

  defp metadata_value(_key, value) when is_atom(value) or is_number(value), do: value

  defp metadata_value(_key, value) when is_pid(value) or is_port(value) or is_reference(value),
    do: inspect(value)

  defp metadata_value(_key, {module, function, arity} = mfa)
       when is_atom(module) and is_atom(function) and is_integer(arity),
       do: mfa

  defp metadata_value(_key, value) when is_list(value) do
    if value != [] and Enum.all?(value, &is_atom/1), do: value, else: @drop
  end

  defp metadata_value(_key, _value), do: @drop
end
