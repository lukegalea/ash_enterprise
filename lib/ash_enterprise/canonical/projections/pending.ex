defmodule AshEnterprise.Canonical.Projections.Pending do
  @moduledoc """
  Project what a Gmail or Slack sync step has landed, at the end of that step
  — the incremental counterpart of `Projections.Gmail.replay/1` and
  `Projections.Slack.replay/3`, so new mail and messages become canonical
  rows minutes after they land instead of when someone replays by hand.

      Pending.project(linked_account, owner: user)
      #=> %{pending: 4, projected: 3, people: 2, denied: 0, denied_by: %{},
      #     shredded: 0, failed: 0}

  ## Why at the end of the step, with its own watermark

  Calendar projects each event right after landing it, before its cursor
  moves, because one event is one canonical row. A Gmail conversation is
  derived from its whole thread and a Slack conversation from its whole
  channel (participants), and a Slack message's sender from a member record
  the step lands last. So these two project once the step has landed
  everything, from what is in `SourceObject`, and keep their own position:
  `AshEnterprise.Integration.ProjectionCursor.projected_through`, the newest
  `fetched_at` a successful projection covered.

  Each call projects the account's records landed after the watermark
  (re-landing refreshes `fetched_at`, so an updated record is projected
  again), with the context the projector needs to write them exactly as a
  replay would (`Gmail.with_threads/2`, `Slack.with_context/2`) and the new
  ones named in `only:`. The watermark moves only after a projection with no
  failed write. A failed write, or a projection that raised, leaves it where
  it was: everything landed stays landed, and the next step projects it again.
  Records that cannot ever be projected (a Gmail payload with no id or date,
  counted `unparseable`) do not hold it back.

  ## Whose rows, through which gate

  Rows are written as the linked account's owner, in its tenant, exactly as
  the replays write them, through the same configured zone gate: a refused
  record is never projected and is counted by reason (`denied_by`). The
  watermark moves past refused records, so records refused while an account
  was untagged are not retried every step; once the operator tags the account
  `mix ash_enterprise.integration.project` projects everything it has landed.
  Writes run under `AshEnterprise.Erasure.LiveScope` in the projectors, so a
  shred that commits first wins: a shredded record is counted (`shredded`),
  never projected.

  ## Counts only

  The summary is counts and reason atoms. A projection that raised is
  reported as `projection_error: :projection_failed` and logged by the
  exception's module name alone — its message could quote content.

  ## Idempotent

  Oban runs a step at least once. Projection is an upsert on the source
  identity (and people on their email), so projecting the same records twice
  converges on the same rows.
  """

  alias AshEnterprise.Canonical.Projections.{Gmail, Slack}
  alias AshEnterprise.Erasure.Shredded
  alias AshEnterprise.Ingestion.SourceObject
  alias AshEnterprise.Integration.Gmail.Sync, as: GmailSync
  alias AshEnterprise.Integration.{LinkedAccount, ProjectionCursor}
  alias AshEnterprise.Integration.Slack.Records, as: SlackRecords

  require Ash.Query
  require Logger

  @integrations %{
    "google-mail" => :gmail,
    "slack" => :slack
  }

  @type summary :: %{
          required(:pending) => non_neg_integer(),
          required(:projected) => non_neg_integer(),
          required(:people) => non_neg_integer(),
          required(:denied) => non_neg_integer(),
          required(:denied_by) => %{atom() => pos_integer()},
          required(:shredded) => non_neg_integer(),
          required(:failed) => non_neg_integer(),
          optional(:projection_error) => :projection_failed
        }

  @doc "The integrations whose landings are projected here."
  def integrations, do: Map.keys(@integrations)

  @doc """
  Project `account`'s records landed since its watermark (with `all?: true`:
  everything it has landed, the operator's catch-up) and move the watermark.

  Options: `:owner` — the account's owner (a `User`; the Gmail rows take their
  business unit from it), defaulting to `account.owner_id`; `:all?`.
  """
  @spec project(LinkedAccount.t(), keyword()) :: summary()
  def project(%LinkedAccount{provider_config_key: key} = account, opts \\ []) do
    vertical = Map.fetch!(@integrations, key)
    watermark = watermark(account.id)
    since = if Keyword.get(opts, :all?, false), do: nil, else: watermark

    case landed_since(vertical, account.id, since) do
      [] -> empty()
      delta -> project_delta(vertical, account, delta, watermark, opts)
    end
  rescue
    # Reduced to structure: an exception from a read or a write can quote the
    # payload. The watermark has not moved; the next step projects again.
    exception ->
      Logger.warning(
        "pending projection failed for a linked account: #{inspect(exception.__struct__)}",
        linked_account_id: account.id
      )

      lineage(:fail, account, reason: "projection_failed")
      Map.put(empty(), :projection_error, :projection_failed)
  end

  defp project_delta(vertical, account, delta, watermark, opts) do
    lineage(:start, account, [])
    counts = run(vertical, account, delta, Keyword.get(opts, :owner, account.owner_id))

    case write_failures(counts) do
      0 ->
        advance(account.id, delta, watermark)
        lineage(:complete, account, [])

      failed ->
        lineage(:fail, account, reason: "#{failed} writes failed")
    end

    %{
      pending: length(delta),
      projected: counts.messages,
      people: counts.people,
      denied: counts.denied,
      denied_by: counts.denied_by,
      shredded: Map.get_lazy(counts, :shredded, fn -> shredded(delta) end),
      failed: counts.failed
    }
  end

  defp run(:gmail, account, delta, owner) do
    {:ok, counts} =
      delta
      |> Gmail.with_threads(account.id)
      |> Gmail.project(owner: owner, tenant: account.organization_id, only: ids(delta))

    counts
  end

  defp run(:slack, account, delta, _owner) do
    {:ok, counts} =
      delta
      |> Slack.with_context(account.id)
      |> Slack.project(account, only: ids(delta))

    counts
  end

  defp ids(delta), do: MapSet.new(delta, & &1.external_id)

  # Hole rule (ADR 0012): projecting landed records into the canonical
  # tables is data movement no single resource action describes, so it is
  # its own job — `canonical.projection.gmail` reads `ingestion_source_objects`
  # and writes the canonical tables. Its run lives inside the sync's
  # correlation (the same lineage run), under its own per-job run id.
  # Datasets are the resources' own (`AshEnterprise.Lineage.dataset/1`), so
  # the graph joins at the nodes their COMPLETE events name.
  @projected [
    AshEnterprise.Canonical.Conversation,
    AshEnterprise.Canonical.Message,
    AshEnterprise.Canonical.Person,
    AshEnterprise.Canonical.ConversationParticipant
  ]

  defp lineage(event, %LinkedAccount{provider_config_key: key} = account, extra) do
    name = "projection.#{Map.fetch!(@integrations, key)}"
    correlation = AshEnterprise.Platform.Correlation.id()

    AshEnterprise.Lineage.ingestion_event(
      event,
      "canonical",
      name,
      [
        run_id: AshEnterprise.Lineage.job_run_id(correlation, "canonical", name),
        correlation_id: correlation,
        inputs: [AshEnterprise.Lineage.dataset(SourceObject)],
        outputs: Enum.map(@projected, &AshEnterprise.Lineage.dataset/1),
        tenant: account.organization_id,
        linked_account_id: account.id
      ] ++ extra
    )
  end

  # Writes that failed may succeed next time; a payload that cannot be parsed
  # never will, so it does not hold the watermark back.
  defp write_failures(counts), do: counts.failed - Map.get(counts, :unparseable, 0)

  defp shredded(delta), do: Enum.count(delta, &Shredded.shredded?(&1.raw_payload))

  defp empty do
    %{
      pending: 0,
      projected: 0,
      people: 0,
      denied: 0,
      denied_by: %{},
      shredded: 0,
      failed: 0
    }
  end

  # --- landed records ------------------------------------------------------------

  defp landed_since(vertical, linked_account_id, since) do
    SourceObject
    |> Ash.Query.filter(external_system == ^external_system(vertical))
    |> Ash.Query.filter(source_metadata["linked_account_id"] == ^linked_account_id)
    |> then(fn query ->
      if since, do: Ash.Query.filter(query, fetched_at > ^since), else: query
    end)
    |> Ash.Query.sort(:external_id)
    |> Ash.read!(authorize?: false)
  end

  defp external_system(:gmail), do: GmailSync.external_system()
  defp external_system(:slack), do: SlackRecords.external_system()

  # --- the watermark ---------------------------------------------------------------

  @doc "The account's watermark: the newest `fetched_at` projected through, or nil."
  @spec watermark(Ash.UUID.t()) :: DateTime.t() | nil
  def watermark(linked_account_id) do
    case ProjectionCursor.for_account(linked_account_id, authorize?: false) do
      {:ok, %ProjectionCursor{projected_through: through}} -> through
      {:ok, nil} -> nil
    end
  end

  # Forward only: a catch-up that read an older landing than a concurrent
  # step's never pulls the watermark back.
  defp advance(linked_account_id, delta, watermark) do
    through = delta |> Enum.map(& &1.fetched_at) |> Enum.max(DateTime)

    if is_nil(watermark) or DateTime.compare(through, watermark) == :gt do
      ProjectionCursor.advance!(
        %{
          linked_account_id: linked_account_id,
          projected_through: through,
          projected_at: DateTime.utc_now()
        },
        authorize?: false
      )
    end

    :ok
  end
end
