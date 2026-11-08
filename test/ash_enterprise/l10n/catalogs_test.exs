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
      "Agent quality",
      "Agent run",
      "Answer",
      "Approval",
      "Artifacts",
      "Arguments: erased",
      "Arguments: none recorded",
      "Attempt",
      "Both are recorded on everything done here.",
      "Builders",
      "By",
      "Cancelled",
      "Case",
      "Compare candidates",
      "Content",
      "Cost",
      "Could not read %{source}",
      "Could not search %{surfaces}. Try again, or open it and search there.",
      "Data freshness unknown",
      "Data read at %{time}",
      "Data read at %{time}, over %{minutes} minutes ago",
      "Decided by",
      "Decision",
      "Definition",
      "Definition invalid",
      "Definition not checked yet",
      "Definition valid",
      "Detail",
      "Diagram",
      "Duration (ms)",
      "Effect",
      "Element",
      "Enter on a licence number or a run id opens that record.",
      "Error",
      "Error class",
      "Error code",
      "Evaluation runs side by side, case by case, with safety in a lane of its own.",
      "Event",
      "Every version of what is authored here, what it references, whether it checks out and what changed.",
      "Everyone",
      "Evidence cited",
      "Execution explorer",
      "Failed",
      "Failure",
      "Hit policy",
      "How agent versions did on the same evaluation cases, with safety kept apart from quality.",
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
      "Model profiles",
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
      "Read again",
      "Reason given",
      "Recent work you may read",
      "Record",
      "Records",
      "Recovery",
      "Result",
      "Reviewers",
      "Reviews and other process tasks you can see that have waited more than two days.",
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
      "Stalled reviews",
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
      "Which model each profile runs, what it may be used for, whether it is known to answer, and what it is restricted from.",
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
      "A candidate fails its injection case",
      "A deploy changes the approved tool",
      "A person asks to be erased",
      "A routing table changes under a case",
      "A shadow rerun must touch nothing",
      "A webhook arrives twice, or early",
      "Armed. The next activation's answer is lost after the registry accepts it, and the registry cannot say afterwards: settle it on the recovery page.",
      "Beat",
      "Beat %{number}",
      "Each failure the tour shows, the beat that shows it, and its record in the execution explorer.",
      "Failure",
      "Lose the registry's answer",
      "No record yet",
      "Nothing to open in the explorer yet.",
      "One parallel check is refused",
      "Open in explorer",
      "Open shadow case %{n}",
      "Open the review packet",
      "Open the review packet for %{number}",
      "Or lose the registry's answer from the fault panel: the registry accepted the activation, the answer never arrived, and when asked afterwards the registry cannot say. Then the request stays outcome unknown, and a person settles it on the recovery surface.",
      "Record",
      "Settle it on the recovery surface",
      "Sign in as rosa@example.com, the coordinator, to ask; as kenji@example.com or amaka@example.com, the committee, to approve. The password is the demo's: password1234 on a local database, or the one in the file the instance was seeded with.",
      "The fault panel is off here. The record below was made beforehand, by the demo's history (mix ash_enterprise.demo --history), through the same actions the panel uses.",
      "The record changes during approval",
      "The registry's answer is lost",
      "The requester's grant is revoked",
      "The review packet shows it before anyone approves: open it on a waiting request after the correction, and its currency says the credential changed since it was asked for. A decided request's packet is read by the clinic's administrator.",
      "The token budget runs out",
      "The twelve failures",
      "The worker-killed variant needs the fault panel on the instance that serves this page: the demo registry keeps its activations in the memory of the application node that took them, so a record made beforehand would be settled by whichever node reconciled it. The record here is the lost answer.",
      "What goes wrong"
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
