defmodule AshEnterprise.Mdm.QualityReview do
  @moduledoc """
  The quality review emit (MDM-7): one audit event per active control for a
  golden record, carrying the facts the rules read.

  The facts are computed here, at the golden — `authorize?: false` reads,
  because this is trusted machinery inside the pipeline, not a person
  surface. The controls come from the MDM rules module's own bundle, never
  from the organization's compliance bundle (the two fact schemas must not
  mix; see `AshEnterprise.Mdm.QualityRules`).
  """

  require Ash.Query

  alias AshCompliance.Resources.{Catalog, Control, ControlRevision}
  alias AshEnterprise.Compliance.EventLog
  alias AshEnterprise.Mdm.SourceIdentity

  @subject_type "person"
  @gaps ~w(mdm.contact mdm.provenance mdm.freshness)

  @doc "Emits the review events for one golden record. Returns :ok."
  def review_golden(tenant, golden, opts \\ []) do
    Enum.each(@gaps, fn gap ->
      metadata = %{
        "organization_id" => tenant,
        "control_id" => gap,
        "subject_type" => @subject_type,
        "subject_id" => to_string(golden.id),
        "correlation_id" => Keyword.get(opts, :correlation_id),
        "facts" => facts(golden, tenant)
      }

      Ash.create!(
        EventLog,
        %{
          record_id: Ecto.UUID.generate(),
          resource: :person,
          action: :mdm_reviewed,
          action_type: :update,
          data: %{},
          metadata: metadata,
          occurred_at:
            Keyword.get(opts, :occurred_at) || DateTime.utc_now() |> DateTime.truncate(:second)
        },
        actor: Keyword.get(opts, :actor)
      )
    end)

    :ok
  end

  @doc "Seeds the MDM quality catalog and controls (idempotent)."
  def seed_quality_catalog(tenant) do
    catalog =
      case Catalog
           |> Ash.Query.filter(organization_id == ^tenant and name == "MDM Quality")
           |> Ash.read_one!(authorize?: false) do
        nil ->
          Ash.create!(Catalog, %{
            organization_id: tenant,
            name: "MDM Quality",
            description: "The MDM golden-record quality baseline (ADR 0050 §10).",
            oscal_uuid: "00000000-0000-0000-0000-00000000bd00"
          })

        catalog ->
          catalog
      end

    Enum.each(
      [
        {"mdm.contact", "Golden records carry a contact address"},
        {"mdm.provenance", "Golden records keep provenance open"},
        {"mdm.freshness", "Golden records are freshly maintained"}
      ],
      fn {gap, title} ->
        case Ash.create(Control, %{
               organization_id: tenant,
               catalog_id: catalog.id,
               control_id: gap,
               title: title
             }) do
          {:ok, control} ->
            {:ok, _} =
              Ash.create(ControlRevision, %{
                control_id: control.id,
                version: "1",
                statement: title,
                status: :active
              })

          {:error, _} ->
            :ok
        end
      end
    )

    :ok
  end

  @doc """
  Starts a `mdm.quality_review` instance for one noncompliant finding —
  the explicit-start path (Resolver + pinned definition struct), which
  avoids the three subscription blockers: no audit-event matching, a
  finding-shaped subject, and cross-tenant baseline resolution through the
  host Resolver. Idempotent per (finding, golden): an instance already
  running for the subject wins.
  """
  def start_stewardship!(tenant, control_id, subject_id, subject \\ nil) do
    case AshEnterprise.Process.Resolver.resolve(:process, "mdm.quality_review", tenant) do
      {:ok, definition} ->
        if quality_instance_running?(tenant, subject_id) do
          :ok
        else
          subject =
            subject ||
              %{
                id: subject_id,
                __struct__: AshEnterprise.Canonical.Person
              }

          AshBpmn.start_instance!(AshEnterprise.Bpmn,
            definition: definition,
            subject: subject,
            actor: AshEnterprise.Platform.SystemActor.system(),
            tenant: tenant,
            correlation_id: control_id
          )

          :ok
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp quality_instance_running?(tenant, subject_id) do
    require Ash.Query

    AshEnterprise.Bpmn.Instance
    |> Ash.Query.filter(
      subject_type == "AshEnterprise.Canonical.Person" and subject_id == ^subject_id and
        status == ^:running
    )
    |> Ash.exists?(tenant: tenant, authorize?: false)
  end

  defp facts(golden, tenant) do
    source_count =
      SourceIdentity
      |> Ash.Query.filter(golden_id == ^golden.id)
      |> Ash.read!(tenant: tenant, authorize?: false)
      |> length()

    subject = "customer"

    # The freshness fact is computed at the golden: boolean, so the closed
    # rule vocabulary stays simple. An never-updated golden is unknown —
    # the triple is simply absent, and absence reads :unknown.
    fresh =
      golden.updated_at &&
        DateTime.diff(DateTime.utc_now(), golden.updated_at, :day) <= 90

    triples = [
      [subject, "mdm_email_present", not is_nil(golden.email)],
      [subject, "mdm_source_count", source_count]
    ]

    if is_nil(fresh) do
      triples
    else
      triples ++ [[subject, "mdm_fresh", fresh]]
    end
  end
end
