defmodule AshEnterprise.L10n.Validator do
  @moduledoc """
  Checks a translator's answer for one batch before the generator uses it.

  The answer is model output, so nothing in it is trusted. A batch is
  accepted whole or refused whole; each problem is reported as
  `{item_id_or_nil, reason}`. Refused:

    * an answer that is not `%{"translations" => [map]}`;
    * a missing translation (an id in the batch with no answer);
    * an invented one (an id not in the batch, or a `msgid` that is not the
      one the id was asked about);
    * a duplicate (the same id twice);
    * an empty string, or a value that is not a string;
    * a singular answer for a plural message, or the reverse;
    * the wrong number of plural forms for the locale;
    * a placeholder mismatch: every `%{name}` in the source must be in the
      translation and the translation may add none. In plural forms
      `%{count}` may be left out (French "un fichier"), but no form may drop
      another placeholder;
    * text a PO file cannot hold as written (a NUL byte).
  """

  @placeholder ~r/%\{([A-Za-z_][A-Za-z0-9_]*)\}/

  @type problem :: {String.t() | nil, String.t()}
  @type translation :: {:singular, String.t()} | {:plural, [String.t()]}

  @doc """
  `{:ok, %{id => translation}}` for `items` (the request's), or
  `{:error, problems}`.
  """
  @spec validate([AshEnterprise.L10n.Translator.item()], term(), pos_integer()) ::
          {:ok, %{String.t() => translation()}} | {:error, [problem()]}
  def validate(items, %{"translations" => answers}, nplurals) when is_list(answers) do
    asked = Map.new(items, &{&1.id, &1})

    {accepted, problems} =
      Enum.reduce(answers, {%{}, []}, fn answer, {accepted, problems} ->
        case check_answer(answer, asked, accepted, nplurals) do
          {:ok, id, translation} -> {Map.put(accepted, id, translation), problems}
          {:error, problem} -> {accepted, [problem | problems]}
        end
      end)

    missing =
      for %{id: id} <- items, not Map.has_key?(accepted, id), not mentioned?(problems, id) do
        {id, "missing translation"}
      end

    case Enum.reverse(problems) ++ missing do
      [] -> {:ok, accepted}
      all -> {:error, all}
    end
  end

  def validate(_items, _answer, _nplurals),
    do: {:error, [{nil, ~s(answer is not %{"translations" => [...]})}]}

  @doc "The `%{name}` placeholders in `text`, as a set of names."
  @spec placeholders(String.t() | nil) :: MapSet.t(String.t())
  def placeholders(nil), do: MapSet.new()

  def placeholders(text) do
    @placeholder |> Regex.scan(text, capture: :all_but_first) |> List.flatten() |> MapSet.new()
  end

  # -- one answer --------------------------------------------------------------

  defp check_answer(%{"id" => id} = answer, asked, accepted, nplurals) when is_binary(id) do
    cond do
      not Map.has_key?(asked, id) -> {:error, {id, "invented id: not in this batch"}}
      Map.has_key?(accepted, id) -> {:error, {id, "duplicate translation"}}
      answer["msgid"] != asked[id].msgid -> {:error, {id, "invented msgid: does not match"}}
      true -> check_value(id, answer, asked[id], nplurals)
    end
  end

  defp check_answer(_answer, _asked, _accepted, _nplurals),
    do: {:error, {nil, "an answer without a string id"}}

  defp check_value(id, answer, %{msgid_plural: nil} = item, _nplurals) do
    case answer do
      %{"msgstr_plural" => _forms} ->
        {:error, {id, "plural answer for a singular message"}}

      %{"msgstr" => msgstr} ->
        with :ok <- text(id, msgstr),
             :ok <- same_placeholders(id, item.msgid, msgstr) do
          {:ok, id, {:singular, msgstr}}
        end

      _no_value ->
        {:error, {id, "no msgstr"}}
    end
  end

  defp check_value(id, answer, item, nplurals) do
    case answer do
      %{"msgstr_plural" => forms} when is_list(forms) and length(forms) == nplurals ->
        with :ok <- all_text(id, forms),
             :ok <- plural_placeholders(id, item, forms) do
          {:ok, id, {:plural, forms}}
        end

      %{"msgstr_plural" => forms} when is_list(forms) ->
        {:error, {id, "#{length(forms)} plural forms, the locale has #{nplurals}"}}

      %{"msgstr" => _singular} ->
        {:error, {id, "singular answer for a plural message"}}

      _no_value ->
        {:error, {id, "no msgstr_plural"}}
    end
  end

  defp text(id, value) when is_binary(value) do
    cond do
      String.trim(value) == "" -> {:error, {id, "empty translation"}}
      not String.valid?(value) -> {:error, {id, "not valid UTF-8"}}
      String.contains?(value, <<0>>) -> {:error, {id, "contains a NUL byte"}}
      true -> :ok
    end
  end

  defp text(id, _value), do: {:error, {id, "translation is not a string"}}

  defp all_text(id, forms) do
    Enum.find_value(forms, :ok, fn form ->
      case text(id, form) do
        :ok -> nil
        error -> error
      end
    end)
  end

  defp same_placeholders(id, source, translation) do
    expected = placeholders(source)
    actual = placeholders(translation)

    if MapSet.equal?(expected, actual),
      do: :ok,
      else: {:error, {id, placeholder_message(expected, actual)}}
  end

  # Each form must carry every non-count placeholder of the source, may leave
  # `%{count}` out, and may add nothing.
  defp plural_placeholders(id, item, forms) do
    source = MapSet.union(placeholders(item.msgid), placeholders(item.msgid_plural))
    required = MapSet.delete(source, "count")

    Enum.find_value(forms, :ok, fn form ->
      actual = placeholders(form)

      if MapSet.subset?(required, actual) and MapSet.subset?(actual, source),
        do: nil,
        else: {:error, {id, placeholder_message(source, actual)}}
    end)
  end

  defp placeholder_message(expected, actual) do
    "placeholders differ: expected #{names(expected)}, got #{names(actual)}"
  end

  defp names(set), do: set |> Enum.sort() |> Enum.map_join(", ", &"%{#{&1}}") |> none()
  defp none(""), do: "none"
  defp none(names), do: names

  defp mentioned?(problems, id), do: Enum.any?(problems, &match?({^id, _}, &1))
end
