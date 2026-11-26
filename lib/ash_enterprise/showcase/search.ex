defmodule AshEnterprise.Showcase.Search do
  @moduledoc """
  The showcase's three-valued search beat: a person writes or picks a filter that
  includes a judged predicate, and the result is three groups, in, out and unknown,
  with each unknown's reason. Unknown is never folded into either side (ADR 0048).

  The searched set is nine invented clinicians (`subjects/0`), seeded once into the
  demo tenant (`seed!/2`). Each has a crisp `city` fact; seven also have a fact for
  the judged question `licence_scan_legible` (`AshEnterprise.SystemOne.ShowcaseSubject`),
  admitted through `AshJudgments.Facts.Materialiser` like any other: three legible, three
  not, and one whose fact has expired. Two were never assessed. Nothing here calls a model
  at read time: a search is a read of those facts.

  ## The path from words to a result

    1. **Propose.** `propose_words/3` turns a search in words into a candidate filter
       (`AshEnterprise.SystemOne.FilterProposal`). In recorded mode
       (`AshEnterprise.Showcase.model_mode/0`) the candidate is the recorded answer for the
       preset searches and nothing else; in live mode it is the in-zone profile's.
    2. **Edit.** The person sees the CQL2 (Basic, JSON) and may change it, or write one
       from nothing, or pick a preset (`presets/0`).
    3. **Approve and run.** `run/4` takes the text exactly as the person left it, records it
       as a proposal (a new version when it differs from the candidate), approves it as the
       person, and runs it (`AshEnterprise.SystemOne.Filter.Runner`) over the clinicians
       only. Refused text runs nothing.

  The reasons an unknown is unknown come from the fold: `"no_fact"` (never assessed) or
  `"expired"` (the fact's validity ran out).
  """

  alias AshEnterprise.Platform.{DemoData, DemoTenant, SystemActor}
  alias AshEnterprise.Security
  alias AshEnterprise.Showcase
  alias AshEnterprise.SystemOne.{Fact, FilterExecution, FilterProposal, ShowcaseSubject}
  alias AshEnterprise.SystemOne.Filter.Runner
  alias AshJudgments.Facts.Materialiser
  alias AshJudgments.Registry.Info

  @subject_type "showcase_clinician"
  @role "Facts search"
  @expired ~U[2026-01-01 00:00:00Z]

  # {id, name, city, what is known about the licence scan}
  @clinicians [
    {"showcase-search-1", "Dr. Amara Okafor", "Toronto", :legible},
    {"showcase-search-2", "Dr. Ben Tremblay", "Ottawa", :legible},
    {"showcase-search-3", "Dr. Chloe Nakamura", "Toronto", :legible},
    {"showcase-search-4", "Dr. Daniel Rossi", "Toronto", :illegible},
    {"showcase-search-5", "Dr. Elena Petrova", "Ottawa", :illegible},
    {"showcase-search-6", "Dr. Farid Haddad", "Hamilton", :illegible},
    {"showcase-search-7", "Dr. Grace Lindqvist", "Toronto", :not_assessed},
    {"showcase-search-8", "Dr. Hiro Yamada", "Ottawa", :not_assessed},
    {"showcase-search-9", "Dr. Imani Brooks", "Toronto", :expired}
  ]

  @doc "The subject type the beat searches over."
  @spec subject_type() :: String.t()
  def subject_type, do: @subject_type

  @doc "The question the beat's judged predicate is, spelled as the filter property."
  @spec question_id() :: String.t()
  def question_id, do: Info.question(ShowcaseSubject, :licence_scan_legible).question_id

  @doc "The searched clinicians: `[%{id:, name:, city:}]`."
  @spec subjects() :: [%{id: String.t(), name: String.t(), city: String.t()}]
  def subjects,
    do: for({id, name, city, _scan} <- @clinicians, do: %{id: id, name: name, city: city})

  @doc """
  The preset searches: `[%{id:, words:, document:}]`, each a filter the person may pick,
  and the words whose recorded translation is that filter.
  """
  @spec presets() :: [%{id: String.t(), words: String.t(), document: map()}]
  def presets do
    legible = %{"property" => question_id()}

    [
      %{
        id: "legible",
        words: "clinicians whose licence scan is legible",
        document: %{"op" => "=", "args" => [legible, true]}
      },
      %{
        id: "illegible",
        words: "clinicians whose licence scan is not legible",
        document: %{"op" => "=", "args" => [legible, false]}
      },
      %{
        id: "toronto_legible",
        words: "clinicians in Toronto whose licence scan is legible",
        document: %{
          "op" => "and",
          "args" => [
            %{"op" => "=", "args" => [%{"property" => "city"}, "Toronto"]},
            %{"op" => "=", "args" => [legible, true]}
          ]
        }
      },
      %{
        id: "not_assessed",
        words: "clinicians whose licence scan has not been assessed",
        document: %{"op" => "isNull", "args" => [legible]}
      }
    ]
  end

  @doc """
  Seeds the beat into the demo tenant: the clinicians' facts, and a role that lets
  `coordinator` read them. Raises unless `organization` is the demo tenant. Running it again
  changes nothing.
  """
  @spec seed!(map(), map()) :: %{facts: non_neg_integer()}
  def seed!(organization, coordinator) do
    DemoTenant.ensure_demo!(organization, "seed the search beat in")
    admit_facts!()
    grant_reading!(organization.id, coordinator)
    %{facts: Enum.sum(for {_id, _name, _city, scan} <- @clinicians, do: 1 + facts_of(scan))}
  end

  defp facts_of(:not_assessed), do: 0
  defp facts_of(_known), do: 1

  defp admit_facts! do
    for {id, _name, city, scan} <- @clinicians do
      admit!(id, "city", city, true)

      case scan do
        :legible -> admit!(id, question_id(), true, true)
        :illegible -> admit!(id, question_id(), false, false)
        :expired -> admit!(id, question_id(), true, true, valid_until: @expired)
        :not_assessed -> :ok
      end
    end
  end

  defp admit!(id, predicate, value, holds, opts \\ []) do
    {:ok, _outcome} =
      Materialiser.materialise(%{
        result: :admitted,
        subject: %{"type" => @subject_type, "id" => id},
        predicate: predicate,
        value: value,
        holds: holds,
        grade: :grant,
        scope: nil,
        valid_until: opts[:valid_until],
        id: Ash.UUID.generate()
      })
  end

  # Reading facts, proposals and runs is what the search needs of a person; proposing,
  # approving and running are person acts, which need no grant.
  defp grant_reading!(tenant, coordinator) do
    actor = SystemActor.seed()
    root = DemoData.root_business_unit!(tenant, actor)
    wanted = MapSet.new([Fact, FilterProposal, FilterExecution], &{inspect(&1), :read})

    privileges =
      Security.Privilege
      |> Ash.read!(actor: actor)
      |> Enum.filter(&MapSet.member?(wanted, {&1.resource_name, &1.access_right}))

    role =
      DemoData.ensure_role!(
        @role,
        "Reads the facts, and the searches and runs made over them.",
        privileges,
        :global,
        root,
        tenant,
        actor
      )

    DemoData.ensure_user_role!(coordinator, role, root, tenant, actor)
  end

  @doc """
  Proposes a filter for a search in words: the recorded translation in recorded mode, the
  in-zone profile's in live mode. `{:ok, proposal}` is a proposal that may be `:refused`
  (its `refusal_reason` says why); `{:error, :not_recorded}` is a search nobody recorded.
  """
  @spec propose_words(String.t(), map(), Ash.UUID.t()) ::
          {:ok, FilterProposal.t()} | {:error, term()}
  def propose_words(words, actor, tenant) do
    case Showcase.model_mode() do
      :live ->
        FilterProposal.propose(nl_text: words, actor: actor, tenant: tenant)

      :recorded ->
        case recorded(words) do
          nil -> {:error, :not_recorded}
          document -> propose(words, Jason.encode!(document), actor, tenant)
        end
    end
  end

  defp recorded(words) do
    wanted = normalise(words)
    Enum.find_value(presets(), &(normalise(&1.words) == wanted && &1.document))
  end

  defp normalise(words), do: words |> String.trim() |> String.downcase()

  defp propose(words, raw, actor, tenant) do
    FilterProposal.propose(
      nl_text: words,
      source: "showcase",
      transport: {:fixed, raw},
      actor: actor,
      tenant: tenant
    )
  end

  @doc """
  Approves and runs the filter `text`, as the person who read it. `proposal` is the candidate
  the text started from (or `nil`): text that differs from its document is stored as a new
  version of it. Returns `{:ok, result}` (`Runner.run/2`'s result) or `{:error, reason}`
  with `reason` a sentence, and nothing has run.
  """
  @spec run(String.t(), FilterProposal.t() | nil, map(), Ash.UUID.t()) ::
          {:ok, map()} | {:error, String.t()}
  def run(text, proposal, actor, tenant) do
    opts = [actor: actor, tenant: tenant]

    with {:ok, document} <- parse(text),
         {:ok, proposal} <- version(proposal, document, text, opts),
         {:ok, approved} <- FilterProposal.approve(proposal, opts),
         {:ok, result} <- Runner.run(approved, opts ++ [subject_type: @subject_type]) do
      {:ok, result}
    else
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, error} -> {:error, Exception.message(error)}
    end
  end

  defp parse(text) do
    case Jason.decode(text) do
      {:ok, document} when is_map(document) -> {:ok, document}
      {:ok, _other} -> {:error, "The filter must be one {\"op\", \"args\"} document."}
      {:error, error} -> {:error, "That is not JSON: " <> Exception.message(error)}
    end
  end

  defp version(
         %FilterProposal{status: :proposed, document: document} = proposal,
         document,
         _text,
         _opts
       ),
       do: {:ok, proposal}

  defp version(%FilterProposal{status: :proposed} = proposal, document, _text, opts),
    do: FilterProposal.edit(proposal, document, opts)

  defp version(_none_or_refused, _document, text, opts) do
    with {:ok, proposal} <- propose("written by hand", text, opts[:actor], opts[:tenant]) do
      case proposal do
        %FilterProposal{status: :proposed} -> {:ok, proposal}
        %FilterProposal{refusal_reason: reason} -> {:error, reason}
      end
    end
  end
end
