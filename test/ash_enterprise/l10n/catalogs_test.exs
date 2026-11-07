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
      "%{n} ms",
      "%{n} tokens",
      "A record's reference or a correlation id",
      "Act",
      "Acting as",
      "Agent run",
      "Answer",
      "Approval",
      "Arguments: erased",
      "Arguments: none recorded",
      "Attempt",
      "Both are recorded on everything done here.",
      "Builders",
      "By",
      "Cancelled",
      "Case",
      "Content",
      "Cost",
      "Could not read %{source}",
      "Could not search %{surfaces}. Try again, or open it and search there.",
      "Decided by",
      "Decision",
      "Definition",
      "Detail",
      "Diagram",
      "Duration (ms)",
      "Effect",
      "Element",
      "Enter on a licence number or a run id opens that record.",
      "Error",
      "Error class",
      "Error code",
      "Event",
      "Everyone",
      "Evidence cited",
      "Execution explorer",
      "Failed",
      "Failure",
      "Hit policy",
      "Impersonated by",
      "Invocation",
      "Judged text",
      "Lifecycle status",
      "Live run",
      "Load more",
      "Matched rules",
      "Members",
      "Model",
      "Model call",
      "More to read from: %{sources}",
      "No app or record matches “%{query}”.",
      "No process run you may read is in this trace.",
      "Nothing in this trace that you may read.",
      "Nothing yet.",
      "Observation",
      "One piece of work, followed through its process, runs, decisions, approvals and calls, on one timeline.",
      "Open the request it asked for",
      "Open the request this reruns",
      "Open the run it graded or belongs to",
      "Operation",
      "Operators",
      "Outcome",
      "Process %{definition}",
      "Process event",
      "Process run",
      "Process status",
      "Profile",
      "Proposal",
      "Question",
      "Ran as",
      "Reason given",
      "Recent work you may read",
      "Record",
      "Records",
      "Recovery",
      "Result",
      "Reviewers",
      "Role",
      "Run mode unknown",
      "Run status",
      "Running",
      "Select an entry on the timeline.",
      "Selected on the diagram: %{name}",
      "Settle an uncertain outcome, simulate or rerun a request, or cancel one, saying why.",
      "Settled as",
      "Show the apps for",
      "Signed in as",
      "Simulated",
      "Some recent work could not be read: %{kinds}. What is listed is not all of it.",
      "Status",
      "Step in on this request (recovery)",
      "Subject",
      "Succeeded",
      "Table version",
      "Target",
      "Task",
      "Task status",
      "Tenant",
      "Test run: %{kind}",
      "The diagram cannot be drawn here. The timeline carries the same selection.",
      "The record behind this entry could not be read. Try again.",
      "The selected entry is not on the diagram.",
      "The trace could not be read: %{reason}",
      "This turn's tool calls could not be read.",
      "Timeline",
      "Tokens",
      "Tool calls",
      "Tools called",
      "Trace",
      "Trace everything recorded with it",
      "Turn",
      "Uncertain",
      "Under",
      "Under it",
      "Waiting",
      "When",
      "You may not read the record behind this entry.",
      "an actor with no email",
      "an operator who could not be named",
      "correlation %{id}",
      "erased",
      "evaluation",
      "experiment",
      "from %{ref}",
      "matched on %{field}",
      "no rule matched",
      "none",
      "not recorded",
      "on %{what}",
      "recorded",
      "sealed in the ledger",
      "sensitive, not shown",
      "shadow, beside live work",
      "the evaluation recorded an error",
      "unknown",
      "yes"
    ],
    {"fr", "showcase"} => [
      "Armed. The next activation's answer is lost after the registry accepts it, and the registry cannot say afterwards: settle it on the recovery page.",
      "Lose the registry's answer"
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
