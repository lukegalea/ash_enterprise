defmodule AshEnterprise.Mdm.People do
  @moduledoc """
  Cross-source people resolution (PROD-9): the same human, seen by Gmail,
  Google Calendar and Slack under different addresses, resolved into one
  golden `AshEnterprise.Canonical.Person` through the ordinary MDM path
  (ADR 0054) — landing, staging, a match rule set as data, the band table,
  the steward queue, the merge.

  The projectors key people on the email address, so one human with a work
  address in Slack and another in Gmail is two rows. Nothing here changes
  that; MDM resolves them afterwards:

    1. **Landing.** `AshEnterprise.Mdm.People.Adapter` observes the people
       the projectors produced — one observation per person per source
       system and linked account — and lands each as a bizev SourceRecord on
       the declared `:canonical` / `:people` stream of
       `AshEnterprise.Mdm.Landing`, beside the CSV upload stream.
    2. **Staging.** An `ImportBatch` against the active `canonical`/`people`
       ingress mapping stages the new or changed observations
       (`AshEnterprise.Mdm.People.Pipeline`).
    3. **Matching.** The tenant's people rule set
       (`AshEnterprise.Mdm.People.Seed`) scores each staged person against
       its own row and against the other people of the same owner; the
       versioned DMN band table decides admit / review / omit.
    4. **Stewardship.** A review-banded pair is an ordinary pending
       `MatchCandidate`: it is in the steward queue and the System One
       review queue, and confirming it is the same person-gated act as for
       an import. Confirming merges the newer person into the older one
       (`:mdm_merge_into`), which moves their identities, meetings, messages
       and conversations (`AshEnterprise.Mdm.PersonJoins`); the unmerge
       moves them back.

  `AshEnterprise.Mdm.People.SweepWorker` runs it per tenant on the `:mdm`
  queue; `mix ash_enterprise.mdm.people` runs it on demand.

  ## Owner-only people

  `Person` is owner-only (ADR 0042): a row is readable by the user whose
  sources produced it and nobody else. The sweep therefore only ever pairs
  people with the same owner — a merge across owners would hand one user's
  correspondence joins to a row another user owns — and the steward queue
  shows a pair only to a reader who may read its golden.

  ## Personal data

  The observation payloads carry the person's name and address (the staged
  row and the steward's side-by-side need them). They land in
  `mdm_source_records`, which no person can read (machinery only); like the
  CSV landings they are outside any erasure scope. Log lines here are counts
  only.
  """

  require Ash.Query

  alias AshEnterprise.Mdm.{ImportBatch, Mapping, MatchCandidate, MatchRuleSet, StagedRecord}

  # The bizev stream (declared in `AshEnterprise.Mdm.Landing`).
  @source :canonical
  @stream :people
  # The ingress mapping's (source, stream), and the batches' slug.
  @mapping_source "canonical"
  @mapping_stream "people"
  @slug "people"

  # The rule set's key. `ash_mdm` keeps ONE active rule set per
  # `golden_resource`, and the CSV import already holds the plain Person key,
  # so the people rule set is scoped by a suffix rather than retiring it. The
  # golden resource is still `Canonical.Person`; the suffix names the flow.
  @rule_set_key "AshEnterprise.Canonical.Person#people"
  @golden "AshEnterprise.Canonical.Person"

  def source, do: @source
  def stream, do: @stream
  def mapping_source, do: @mapping_source
  def mapping_stream, do: @mapping_stream
  def slug, do: @slug
  def rule_set_key, do: @rule_set_key
  def golden_resource, do: @golden

  @doc "The tenant's active people ingress mapping, or nil."
  def mapping(tenant) do
    Mapping
    |> Ash.Query.filter(
      direction == :ingress and source == ^@mapping_source and stream == ^@mapping_stream and
        status == :active
    )
    |> Ash.read_one!(tenant: tenant, authorize?: false)
  end

  @doc "The tenant's active people match rule set, or nil."
  def rule_set(tenant) do
    MatchRuleSet
    |> Ash.Query.filter(golden_resource == ^@rule_set_key and status == :active)
    |> Ash.read_one!(tenant: tenant, authorize?: false)
  end

  @doc "Whether a staged record came in through the people source."
  def staged?(%StagedRecord{source_record_id: id}) do
    case Ash.get(AshEnterprise.Mdm.SourceRecord, id, authorize?: false, error?: false) do
      {:ok, %{source: @source, stream: @stream}} -> true
      _ -> false
    end
  end

  @doc """
  How many people pairs wait for a steward that the reader may decide —
  counts only (the morning brief's line). Reads the steward queue as the
  caller (`opts`: `actor:`, `tenant:`), so a pair whose golden they may not
  read is not counted.
  """
  @spec review_count(keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def review_count(opts) do
    case Keyword.get(opts, :tenant) do
      nil -> {:ok, 0}
      tenant -> review_count(tenant, opts)
    end
  end

  defp review_count(tenant, opts) do
    staged_ids =
      StagedRecord
      |> Ash.Query.filter(
        status == :review and
          batch_id in ^people_batch_ids(tenant)
      )
      |> Ash.Query.select([:id])
      |> Ash.read!(tenant: tenant, authorize?: false)
      |> Enum.map(& &1.id)

    case staged_ids do
      [] ->
        {:ok, 0}

      ids ->
        MatchCandidate
        |> Ash.Query.for_read(:review_queue, %{}, opts)
        |> Ash.Query.filter(staged_record_id in ^ids)
        |> Ash.count(opts)
    end
  end

  defp people_batch_ids(tenant) do
    ImportBatch
    |> Ash.Query.filter(source_slug == ^@slug and mapping.source == ^@mapping_source)
    |> Ash.Query.select([:id])
    |> Ash.read!(tenant: tenant, authorize?: false)
    |> Enum.map(& &1.id)
  end
end
