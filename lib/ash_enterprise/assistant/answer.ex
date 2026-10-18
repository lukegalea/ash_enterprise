defmodule AshEnterprise.Assistant.Answer do
  @moduledoc """
  An answer's text as the page shows it: paragraphs and short lists, with
  `[[<surface>:<id>]]` citations turned into numbered links.

  The model writes plain text (`AshEnterprise.Assistant.Prompt`). This turns
  it into **structure, never HTML**: blocks of tokens the LiveView renders
  with ordinary components, so nothing the model writes is ever marked safe.

  ## Citations

  A citation becomes a link only when its ref is one the run's tools returned
  (`Turn.refs`); anything else the model wrote between double brackets is
  dropped rather than linked, so an invented id never looks like a source.
  A link goes to `/app/r/<surface>/<id>`, which re-authorizes the record as
  the reader (`AshEnterprise.Surfaces.Records`).
  """

  alias AshEnterprise.Surfaces

  @typedoc "One inline piece of a line."
  @type token ::
          {:text, String.t()}
          | {:strong, String.t()}
          | {:code, String.t()}
          | {:cite, pos_integer(), String.t()}

  @typedoc "A paragraph, or a list of items."
  @type block :: {:p, [[token()]]} | {:ul, [[token()]]}

  @typedoc "A cited record: its number, ref, the surface it opens on and the link."
  @type source :: %{n: pos_integer(), ref: String.t(), label: String.t(), path: String.t()}

  @cite ~r/\[\[\s*([^\[\]]+?)\s*\]\]/u
  @ref ~r/^([a-z_]+):([0-9a-fA-F-]{36})$/

  @doc """
  Parses `text` against the citable `refs`: `%{blocks: [block], sources: [source]}`.
  Sources are numbered in order of first citation.
  """
  @spec parse(String.t() | nil, Enumerable.t()) :: %{blocks: [block()], sources: [source()]}
  def parse(text, refs) when is_binary(text) do
    allowed = MapSet.new(refs || [])
    {lines, sources} = cite_lines(String.split(text, ~r/\r?\n/), allowed)
    %{blocks: blocks(lines), sources: Enum.reverse(sources)}
  end

  def parse(_text, _refs), do: %{blocks: [], sources: []}

  @doc "The deep link for a ref, or nil when it is not a registry record ref."
  @spec path(String.t()) :: String.t() | nil
  def path(ref) do
    case Regex.run(@ref, ref) do
      [_, surface, id] ->
        if Surfaces.fetch(surface), do: "/app/r/#{surface}/#{String.downcase(id)}"

      _ ->
        nil
    end
  end

  # Each line becomes {kind, tokens}; citation numbers are shared across lines.
  defp cite_lines(lines, allowed) do
    Enum.map_reduce(lines, [], fn line, sources ->
      {kind, body} = kind(line)
      {tokens, sources} = tokens(body, allowed, sources)
      {{kind, tokens}, sources}
    end)
  end

  defp kind(line) do
    trimmed = String.trim(line)

    cond do
      trimmed == "" ->
        {:blank, ""}

      Regex.match?(~r/^([-*•]|\d+[.)])\s+/u, trimmed) ->
        {:item, Regex.replace(~r/^([-*•]|\d+[.)])\s+/u, trimmed, "")}

      true ->
        {:line, Regex.replace(~r/^#+\s*/u, trimmed, "")}
    end
  end

  defp tokens(body, allowed, sources) do
    @cite
    |> Regex.split(body, include_captures: true, trim: true)
    |> Enum.flat_map_reduce(sources, fn piece, sources ->
      case Regex.run(@cite, piece) do
        [_, inner] -> cites(inner, allowed, sources)
        nil -> {inline(piece), sources}
      end
    end)
    |> then(fn {tokens, sources} -> {tidy(tokens), sources} end)
  end

  defp cites(inner, allowed, sources) do
    inner
    |> String.split([",", ";", " "], trim: true)
    |> Enum.flat_map_reduce(sources, fn ref, sources ->
      ref = String.trim(ref)

      with true <- MapSet.member?(allowed, ref),
           path when is_binary(path) <- path(ref) do
        number(sources, ref, path)
      else
        _ -> {[], sources}
      end
    end)
  end

  # A ref cited before keeps its number; a new one takes the next.
  defp number(sources, ref, path) do
    case Enum.find(sources, &(&1.ref == ref)) do
      %{n: n} ->
        {[{:cite, n, path}], sources}

      nil ->
        n = length(sources) + 1
        {[{:cite, n, path}], [source(n, ref, path) | sources]}
    end
  end

  defp source(n, ref, path) do
    [surface | _] = String.split(ref, ":", parts: 2)

    label =
      case Surfaces.fetch(surface) do
        %{label: label} -> label
        nil -> surface
      end

    %{n: n, ref: ref, label: label, path: path}
  end

  # **bold** and `code`, everything else text.
  defp inline(text) do
    ~r/(\*\*[^*]+\*\*|`[^`]+`)/u
    |> Regex.split(text, include_captures: true, trim: true)
    |> Enum.map(fn
      "**" <> rest -> {:strong, String.trim_trailing(rest, "**")}
      "`" <> rest -> {:code, String.trim_trailing(rest, "`")}
      plain -> {:text, plain}
    end)
  end

  # A citation's surrounding space: "fact [1]." not "fact  [1] ."
  defp tidy(tokens), do: Enum.reject(tokens, &(&1 == {:text, ""}))

  # Consecutive lines form a paragraph (one line each); consecutive items a list.
  defp blocks(lines) do
    lines
    |> Enum.chunk_by(fn {kind, _} -> kind end)
    |> Enum.flat_map(fn
      [{:blank, _} | _] -> []
      [{:item, _} | _] = items -> [{:ul, Enum.map(items, &elem(&1, 1))}]
      [{:line, _} | _] = paragraph -> [{:p, Enum.map(paragraph, &elem(&1, 1))}]
    end)
  end
end
