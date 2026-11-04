defmodule AshEnterprise.L10n.Generator do
  @default_batch_size 20
  @max_batch_size 50

  @moduledoc """
  Fills the untranslated messages of one PO catalog through a translator
  (`AshEnterprise.L10n.Translator`), at design time (ADR 0060, section 3).
  `mix l10n.generate` is the way a person runs it.

  ## What it guarantees

    * **Only empty messages are sent.** A message with a translation is never
      sent or changed, so a reviewed translation survives every later run.
    * **Deterministic, ordered, bounded batches.** Untranslated messages go in
      file order, `:batch_size` at a time (at most #{@max_batch_size}), one batch after
      another. The same catalog produces the same requests.
    * **Nothing unvalidated is written.** Each answer passes
      `AshEnterprise.L10n.Validator` (missing, invented or duplicate msgids,
      empty strings, placeholder and plural mismatches) or the whole run is
      refused and the catalog left as it was. The composed catalog must parse
      again before it is returned.
    * **Idempotent.** A catalog with nothing to translate comes back byte for
      byte, and a run's output fed back in is a no-op.

  Source context rides along with each message (its `msgctxt`, references and
  extracted comments), and a glossary pins the product's own words.
  """

  alias AshEnterprise.L10n.Validator
  alias Expo.Message
  alias Expo.Messages

  @type stats :: %{translated: non_neg_integer(), batches: non_neg_integer()}

  @doc """
  Translates `content` (a PO file's text) into `opts[:locale]`.

  Options:

    * `:locale` (required) — the Gettext locale being written, e.g. `"fr"`.
    * `:translator` (required) — a module implementing
      `AshEnterprise.L10n.Translator`.
    * `:translator_opts` — passed to the translator untouched.
    * `:domain` — the catalog's name, for the model's context.
    * `:glossary` — `%{source term => required translation}`.
    * `:batch_size` — messages per request, 1..#{@max_batch_size}
      (default #{@default_batch_size}).

  Returns `{:ok, new_content, stats}` or `{:error, problems}`, where each
  problem is `{msgid_or_nil, reason}`.
  """
  @spec generate(String.t(), keyword()) ::
          {:ok, String.t(), stats()} | {:error, [{String.t() | nil, String.t()}]}
  def generate(content, opts) when is_binary(content) do
    locale = Keyword.fetch!(opts, :locale)

    with {:ok, batch_size} <- batch_size(opts),
         {:ok, po} <- parse(content),
         {:ok, nplurals} <- nplurals(po, locale) do
      po
      |> pending()
      |> translate(po, content, locale, nplurals, Keyword.put(opts, :batch_size, batch_size))
    end
  end

  defp translate([], _po, content, _locale, _nplurals, _opts),
    do: {:ok, content, %{translated: 0, batches: 0}}

  defp translate(pending, po, _content, locale, nplurals, opts) do
    batches = Enum.chunk_every(pending, opts[:batch_size])
    request = base_request(locale, nplurals, opts)

    with {:ok, translations} <- translate_batches(batches, request, opts),
         {:ok, composed} <- compose(po, translations) do
      {:ok, composed, %{translated: map_size(translations), batches: length(batches)}}
    end
  end

  # -- reading -----------------------------------------------------------------

  defp batch_size(opts) do
    case Keyword.get(opts, :batch_size, @default_batch_size) do
      n when is_integer(n) and n in 1..@max_batch_size ->
        {:ok, n}

      other ->
        {:error, [{nil, "batch size must be 1..#{@max_batch_size}, got #{inspect(other)}"}]}
    end
  end

  defp parse(content) do
    case Expo.PO.parse_string(content) do
      {:ok, po} -> {:ok, po}
      {:error, error} -> {:error, [{nil, "invalid PO: " <> Exception.message(error)}]}
    end
  end

  # The catalog's own Plural-Forms header decides; a catalog without one
  # takes Gettext's rule for the locale.
  defp nplurals(po, locale) do
    case Messages.get_header(po, "Plural-Forms") do
      [header | _] ->
        case Expo.PluralForms.parse(header) do
          {:ok, %{nplurals: n}} -> {:ok, n}
          {:error, _error} -> {:error, [{nil, "invalid Plural-Forms header"}]}
        end

      [] ->
        {:ok, Gettext.Plural.nplurals(locale)}
    end
  end

  # Untranslated, live messages in file order, each with its position.
  defp pending(po) do
    po.messages
    |> Enum.with_index()
    |> Enum.filter(fn {message, _index} -> not message.obsolete and untranslated?(message) end)
  end

  defp untranslated?(%Message.Singular{msgstr: msgstr}), do: blank?(msgstr)

  defp untranslated?(%Message.Plural{msgstr: forms}),
    do: forms == %{} or Enum.any?(Map.values(forms), &blank?/1)

  defp blank?(iodata), do: iodata |> IO.iodata_to_binary() |> String.trim() == ""

  # -- asking ------------------------------------------------------------------

  defp base_request(locale, nplurals, opts) do
    %{
      locale: locale,
      domain: Keyword.get(opts, :domain, "default"),
      nplurals: nplurals,
      glossary: Keyword.get(opts, :glossary, %{})
    }
  end

  defp translate_batches(batches, request, opts) do
    translator = Keyword.fetch!(opts, :translator)
    translator_opts = Keyword.get(opts, :translator_opts, [])

    Enum.reduce_while(batches, {:ok, %{}}, fn batch, {:ok, acc} ->
      case translate_batch(batch, request, translator, translator_opts) do
        {:ok, translated} -> {:cont, {:ok, Map.merge(acc, translated)}}
        {:error, problems} -> {:halt, {:error, problems}}
      end
    end)
  end

  # `%{message index => translation}` for one batch, or its named problems.
  defp translate_batch(batch, request, translator, translator_opts) do
    items = items(batch)
    by_id = Map.new(Enum.zip(items, batch), fn {item, {_message, index}} -> {item.id, index} end)

    with {:ok, answer} <- call(translator, Map.put(request, :items, items), translator_opts),
         {:ok, accepted} <- Validator.validate(items, answer, request.nplurals) do
      {:ok, Map.new(accepted, fn {id, translation} -> {by_id[id], translation} end)}
    else
      {:error, problems} -> {:error, name_problems(problems, items)}
    end
  end

  defp call(translator, request, opts) do
    case translator.translate(request, opts) do
      {:ok, answer} -> {:ok, answer}
      {:error, reason} -> {:error, [{nil, "translator failed: " <> describe(reason)}]}
      other -> {:error, [{nil, "translator returned " <> describe(other)}]}
    end
  end

  defp describe(reason) when is_binary(reason), do: reason
  defp describe(%{__exception__: true} = error), do: Exception.message(error)
  defp describe(reason), do: inspect(reason, limit: 5, printable_limit: 200)

  # Ids are positions within the batch: short, and meaningless outside it.
  defp items(batch) do
    batch
    |> Enum.with_index(1)
    |> Enum.map(fn {{message, _index}, position} ->
      message |> build_item() |> Map.put(:id, Integer.to_string(position))
    end)
  end

  defp build_item(%Message.Singular{} = message), do: base_item(message, nil)

  defp build_item(%Message.Plural{} = message),
    do: base_item(message, IO.iodata_to_binary(message.msgid_plural))

  defp base_item(message, msgid_plural) do
    %{
      msgid: IO.iodata_to_binary(message.msgid),
      msgid_plural: msgid_plural,
      msgctxt: message.msgctxt && IO.iodata_to_binary(message.msgctxt),
      comments: comments(message)
    }
  end

  defp comments(message) do
    references =
      message.references
      |> List.flatten()
      |> Enum.map(fn
        {file, line} -> "#{file}:#{line}"
        file -> file
      end)

    message.extracted_comments ++ references
  end

  # Problems name the msgid they are about, not the batch-local id.
  defp name_problems(problems, items) do
    msgids = Map.new(items, &{&1.id, &1.msgid})
    Enum.map(problems, fn {id, reason} -> {Map.get(msgids, id, id), reason} end)
  end

  # -- writing -----------------------------------------------------------------

  defp compose(po, translations) do
    messages =
      po.messages
      |> Enum.with_index()
      |> Enum.map(fn {message, index} ->
        case Map.fetch(translations, index) do
          {:ok, translation} -> apply_translation(message, translation)
          :error -> message
        end
      end)

    composed = %{po | messages: messages} |> Expo.PO.compose() |> IO.iodata_to_binary()

    case Expo.PO.parse_string(composed) do
      {:ok, _reparsed} ->
        {:ok, composed}

      {:error, error} ->
        {:error, [{nil, "composed PO does not parse: " <> Exception.message(error)}]}
    end
  end

  defp apply_translation(%Message.Singular{} = message, {:singular, msgstr}),
    do: %{message | msgstr: [msgstr]}

  defp apply_translation(%Message.Plural{} = message, {:plural, forms}) do
    msgstr = forms |> Enum.with_index() |> Map.new(fn {form, n} -> {n, [form]} end)
    %{message | msgstr: msgstr}
  end
end
