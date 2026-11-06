defmodule AshEnterprise.L10n.CatalogsTest do
  @moduledoc """
  The committed catalogs (ADR 0060 release gates): every PO file parses, each
  locale's catalog holds exactly its template's messages, and every
  translation keeps its source's placeholders and the locale's plural count.

  That the templates themselves match the source is the CI step
  `mix gettext.extract --check-up-to-date`; this checks the layer under it,
  which that step does not.
  """

  use ExUnit.Case, async: true

  alias AshEnterprise.L10n.Validator
  alias Expo.Message

  @root "priv/gettext"

  # Catalogs a person translated in full. A message added to a template
  # without a French translation fails here, not in front of a French reader.
  @complete %{"fr" => ~w(default auth errors showcase assistant)}

  # Messages added in English that wait for one reviewed French pass, rather
  # than each change guessing at French. Named here, by locale and domain, so a
  # gap is a listed decision, never an accident; a message listed here that has
  # since been translated fails too, so the list only shrinks.
  @awaiting %{
    {"fr", "default"} => [
      "Builders",
      "Could not search %{surfaces}. Try again, or open it and search there.",
      "Enter on a licence number or a run id opens that record.",
      "Everyone",
      "Members",
      "No app or record matches “%{query}”.",
      "Operators",
      "Records",
      "Reviewers",
      "Show the apps for",
      "matched on %{field}"
    ]
  }

  defp templates, do: @root |> Path.join("*.pot") |> Path.wildcard() |> Enum.sort()

  defp locales do
    @root
    |> File.ls!()
    |> Enum.filter(&File.dir?(Path.join([@root, &1, "LC_MESSAGES"])))
    |> Enum.sort()
  end

  defp parse!(path) do
    case Expo.PO.parse_file(path) do
      {:ok, po} -> po
      {:error, error} -> flunk("#{path} does not parse: #{Exception.message(error)}")
    end
  end

  defp keys(po), do: po.messages |> Enum.reject(& &1.obsolete) |> MapSet.new(&Message.key/1)

  test "the catalogs this change ships exist" do
    assert "fr" in locales()

    for domain <- ~w(default auth errors),
        do: assert(File.exists?(Path.join(@root, domain <> ".pot")))
  end

  test "every locale has every template's messages, and no others" do
    for pot_path <- templates(), locale <- locales() do
      domain = Path.basename(pot_path, ".pot")
      po_path = Path.join([@root, locale, "LC_MESSAGES", domain <> ".po"])

      assert File.exists?(po_path),
             "#{po_path} is missing; run mix gettext.merge priv/gettext --locale #{locale}"

      expected = pot_path |> parse!() |> keys()
      actual = po_path |> parse!() |> keys()

      assert MapSet.difference(expected, actual) == MapSet.new(),
             "#{po_path} lacks messages from #{pot_path}; run mix gettext.extract --merge"

      assert MapSet.difference(actual, expected) == MapSet.new(),
             "#{po_path} has messages its template dropped; run mix gettext.extract --merge"
    end
  end

  test "translations keep their placeholders and the locale's plural forms" do
    for locale <- locales(),
        po_path <- Path.wildcard(Path.join([@root, locale, "LC_MESSAGES", "*.po"])) do
      po = parse!(po_path)
      nplurals = nplurals(po, locale)

      for message <- po.messages, not message.obsolete do
        check(po_path, message)

        if match?(%Message.Plural{}, message) do
          assert map_size(message.msgstr) == nplurals,
                 "#{po_path}: #{inspect(message.msgid)} has #{map_size(message.msgstr)} forms, the catalog #{nplurals}"
        end
      end
    end
  end

  test "the fully translated catalogs have no empty message" do
    for {locale, domains} <- @complete, domain <- domains do
      po_path = Path.join([@root, locale, "LC_MESSAGES", domain <> ".po"])

      empty =
        for message <- parse!(po_path).messages, not message.obsolete, empty?(message) do
          IO.iodata_to_binary(message.msgid)
        end

      awaiting = Map.get(@awaiting, {locale, domain}, [])

      assert empty -- awaiting == [],
             "#{po_path} has untranslated messages: #{inspect(empty -- awaiting)}"

      assert awaiting -- empty == [],
             "#{po_path} translates or no longer has #{inspect(awaiting -- empty)}; drop them from @awaiting"
    end
  end

  defp check(path, %Message.Singular{msgid: msgid, msgstr: msgstr}) do
    source = IO.iodata_to_binary(msgid)
    translation = IO.iodata_to_binary(msgstr)

    if translation != "" do
      assert Validator.placeholders(translation) == Validator.placeholders(source),
             "#{path}: #{inspect(translation)} changes the placeholders of #{inspect(source)}"
    end
  end

  defp check(path, %Message.Plural{} = message) do
    source =
      MapSet.union(
        Validator.placeholders(IO.iodata_to_binary(message.msgid)),
        Validator.placeholders(IO.iodata_to_binary(message.msgid_plural))
      )

    for {_n, form} <- message.msgstr, (text = IO.iodata_to_binary(form)) != "" do
      placeholders = Validator.placeholders(text)

      assert MapSet.subset?(MapSet.delete(source, "count"), placeholders) and
               MapSet.subset?(placeholders, source),
             "#{path}: #{inspect(text)} changes the placeholders of #{inspect(message.msgid)}"
    end
  end

  # The catalog's header decides; without one, Gettext's rule for the locale.
  defp nplurals(po, locale) do
    case Expo.Messages.get_header(po, "Plural-Forms") do
      [header | _] -> Expo.PluralForms.parse!(header).nplurals
      [] -> Gettext.Plural.nplurals(locale)
    end
  end

  defp empty?(%Message.Singular{msgstr: msgstr}), do: IO.iodata_to_binary(msgstr) == ""

  defp empty?(%Message.Plural{msgstr: forms}),
    do: Enum.any?(forms, fn {_n, form} -> IO.iodata_to_binary(form) == "" end)
end
