defmodule AshEnterprise.Mdm.DemoData do
  @moduledoc """
  One-command MDM demo (`mix ash_enterprise.demo`): fills the seeded tenant
  with just enough entity-resolution state to walk the UI end to end —

  - the platform baselines (seed bands, the steward-review BPMN definition),
  - an active match rule set and an active ingress mapping,
  - one golden Person with a merged duplicate (the golden surface shows
    lineage immediately),
  - one in-flight import whose review-banded match is waiting in the
    steward queue.

  Idempotent by construction: every section checks for its own rows first
  and skips when they exist, so re-running the task changes nothing.
  """

  alias AshEnterprise.Canonical.Person
  alias AshEnterprise.Mdm.{ImportBatch, Landing, Mapping, MatchCandidate, MatchRuleSet}

  require Ash.Query

  # The demo's own mapping stream — a capture run leaves other active
  # ingress mappings behind, and the in-flight import must pin THIS one.
  @demo_stream "demo_contacts"

  def populate(org_id, admin) do
    seed_baselines!()
    seed_rule_set!(org_id, admin)
    seed_mapping!(org_id, admin)
    seed_golden_with_loser!(org_id, admin)
    seed_in_flight_import!(org_id, admin)

    %{
      goldens: Person |> Ash.read!(tenant: org_id, authorize?: false) |> length(),
      review_pending: pending_review_count(org_id),
      merged: merged_count(org_id)
    }
  end

  # -- baselines (platform org) ----------------------------------------------

  defp seed_baselines!, do: AshEnterprise.Mdm.Baselines.ensure!()

  @doc "See `AshEnterprise.Mdm.Baselines.publish_steward_review!/0`."
  @spec publish_steward_review!() :: :unchanged | {:published, pos_integer()}
  defdelegate publish_steward_review!, to: AshEnterprise.Mdm.Baselines

  # -- tenant machinery -------------------------------------------------------

  defp seed_rule_set!(org_id, admin) do
    active? =
      MatchRuleSet
      |> Ash.Query.filter(
        golden_resource == ^"AshEnterprise.Canonical.Person" and status == ^:active
      )
      |> Ash.exists?(tenant: org_id, authorize?: false)

    if active? do
      :ok
    else
      rules = [
        %{"name" => "email_exact", "kind" => "exact", "fields" => ["email"], "weight" => 1.0},
        %{
          "name" => "name_fuzzy",
          "kind" => "fuzzy",
          "field" => "name",
          "algorithm" => "levenshtein",
          "weight" => 0.5
        }
      ]

      MatchRuleSet
      |> Ash.Changeset.for_create(:draft, %{
        golden_resource: "AshEnterprise.Canonical.Person",
        rules: rules
      })
      |> Ash.create!(tenant: org_id, authorize?: false)
      |> Ash.Changeset.for_update(:activate, %{}, tenant: org_id, actor: admin)
      |> Ash.update!(tenant: org_id, actor: admin)
    end
  end

  defp seed_mapping!(org_id, admin) do
    active? =
      Mapping
      |> Ash.Query.filter(
        direction == ^:ingress and source == ^"manual_csv" and status == ^:active
      )
      |> Ash.exists?(tenant: org_id, authorize?: false)

    if active? do
      :ok
    else
      field_rules = [
        %{"path" => "Email", "target" => "email", "op" => "trim", "args" => %{}},
        %{"path" => "Full Name", "target" => "name", "op" => "identity", "args" => %{}}
      ]

      Mapping
      |> Ash.Changeset.for_create(:draft, %{
        direction: :ingress,
        source: "manual_csv",
        stream: @demo_stream,
        target_resource: "AshEnterprise.Canonical.Person",
        field_rules: field_rules,
        observed_schema: %{"Email" => %{}, "Full Name" => %{}}
      })
      |> Ash.create!(tenant: org_id, authorize?: false)
      |> then(fn mapping ->
        mapping
        |> Ash.Changeset.for_update(:validate, %{}, tenant: org_id, authorize?: false)
        |> Ash.update!(tenant: org_id, authorize?: false)
      end)
      |> Ash.reload!(tenant: org_id, authorize?: false)
      |> Ash.Changeset.for_update(:activate, %{activation_note: "demo seed"},
        tenant: org_id,
        actor: admin
      )
      |> Ash.update!(tenant: org_id, actor: admin)
    end
  end

  # -- golden + merged duplicate ----------------------------------------------

  defp seed_golden_with_loser!(org_id, admin) do
    ann =
      Person
      |> Ash.Query.filter(email == ^"ann@x.io")
      |> Ash.read_one!(tenant: org_id, authorize?: false)

    ann =
      ann ||
        Person
        |> Ash.Changeset.for_create(:upsert_from_source, %{
          name: "Ann Existing",
          email: "ann@x.io",
          owner_id: admin.id,
          owning_business_unit_id: admin.owning_business_unit_id
        })
        |> Ash.create!(tenant: org_id, authorize?: false)

    merged_count(org_id) == 0 &&
      Person
      |> Ash.Changeset.for_create(:upsert_from_source, %{
        name: "Ann Duplicate",
        email: "ann.duplicate@x.io",
        owner_id: admin.id,
        owning_business_unit_id: admin.owning_business_unit_id
      })
      |> Ash.create!(tenant: org_id, authorize?: false)
      |> Ash.Changeset.for_update(:mdm_merge_into, %{survivor_id: ann.id},
        tenant: org_id,
        actor: admin
      )
      |> Ash.update!(tenant: org_id, actor: admin)

    :ok
  end

  # -- one import in flight -----------------------------------------------------

  defp seed_in_flight_import!(org_id, admin) do
    if pending_review_count(org_id) > 0 do
      :ok
    else
      mapping = demo_mapping!(org_id, admin)

      # Unique slug per run: stage_batch stages every landed row under the
      # batch's slug, so a fixed slug would re-stage all earlier demo rows
      # on each re-run (and System.unique_integer is only unique within one
      # VM). The batch's slug is independent of the mapping's stream — the
      # mapping_id pins the rules; the slug names the source batch.
      slug = "demo-" <> Ash.UUID.generate()

      for {key, payload} <- [
            {"demo-fuzzy", %{"Email" => "ann@x.io", "Full Name" => "Ann Existing-Smith"}},
            {"demo-new", %{"Email" => "nadia@x.io", "Full Name" => "Nadia New"}}
          ] do
        {:ok, _} = Landing.land_row(org_id, slug, payload, row_key: key)
      end

      batch =
        ImportBatch
        |> Ash.Changeset.for_create(:open, %{mapping_id: mapping.id, source_slug: slug},
          tenant: org_id,
          actor: admin
        )
        |> Ash.create!(tenant: org_id, actor: admin)

      {:ok, _} =
        %{"batch_id" => batch.id, "tenant" => batch.organization_id}
        |> AshEnterprise.Mdm.BatchWorker.new()
        |> Oban.insert()

      Oban.drain_queue(queue: :mdm, with_safety: false)
      Oban.drain_queue(queue: :bpmn, with_safety: false)

      # Under a live Oban (mix task boot) the running instance may have
      # picked the job up before the drain saw it — wait for it to finish
      # instead of leaving it mid-flight when this process exits.
      wait_for_job(batch.id)

      :ok
    end
  end

  defp wait_for_job(batch_id, deadline \\ System.monotonic_time(:second) + 60) do
    import Ecto.Query, only: [from: 2]

    state =
      AshEnterprise.Repo.one!(
        from(j in Oban.Job,
          where: j.queue == "mdm" and j.args["batch_id"] == ^batch_id,
          select: j.state,
          order_by: [desc: j.id],
          limit: 1
        )
      )

    cond do
      state in ~w(completed discarded cancelled failed) ->
        :ok

      System.monotonic_time(:second) > deadline ->
        raise "demo import batch #{batch_id} did not finish (job state: #{state})"

      true ->
        Process.sleep(250)
        wait_for_job(batch_id, deadline)
    end
  end

  defp demo_mapping!(org_id, admin) do
    mapping =
      Mapping
      |> Ash.Query.filter(stream == ^@demo_stream and status == ^:active)
      |> Ash.read_one!(tenant: org_id, authorize?: false)

    mapping || (seed_mapping!(org_id, admin) && active_demo_mapping!(org_id))
  end

  defp active_demo_mapping!(org_id) do
    Mapping
    |> Ash.Query.filter(stream == ^@demo_stream and status == ^:active)
    |> Ash.read_one!(tenant: org_id, authorize?: false)
  end

  defp pending_review_count(org_id) do
    MatchCandidate
    |> Ash.Query.filter(band == ^:review and status == ^:pending)
    |> Ash.count!(tenant: org_id, authorize?: false)
  end

  defp merged_count(org_id) do
    Person
    |> Ash.Query.filter(merged == true)
    |> Ash.count!(tenant: org_id, authorize?: false)
  end
end
