defmodule AshEnterprise.Artifacts do
  @moduledoc """
  The artifact registry: every versioned thing a person authors, reviews or releases,
  declared once, a sibling of `AshEnterprise.Surfaces`. The mechanism is the
  `ash_versions` package (`AshVersions.Registry`); this module is the host's side of it:
  the entries, the tenant, the doors, who published (from the audit trail), the labels
  and the paths.

  An entry (`AshVersions.Artifact`) names a resource and what the artifact
  pages need to know about its rows: which attribute is the version, how a version finds
  its predecessor, its lifecycle and which states are drafts, its scope, content hash,
  parent, what it references, how it is checked and how two versions are compared. From
  the entry alone a type gets:

    * **discovery**: listed on `/app/artifacts`, newest first, read as the viewer
      (`discover/1`);
    * **a header**: identity, version, lifecycle, content hash, provenance and who
      published it (`header/3`), with the run it was opened from, so a draft cannot pass
      for the version a run used (`used_by/4`);
    * **a semantic diff** against its predecessor or any other version (`diff/4`);
    * **validation**: the stored version checked again (`validation/2`).

  ## Adding a type

  Add an `%Artifact{}` to `@artifacts` below, and, for a diff, a module implementing
  `AshVersions.Differ` named in `differ:`. Its `aspects/0` says what it
  compares; its `diff/3` compares by meaning (graph nodes, cases, tools), never by text.
  A type with no differ shows "no semantic diff for this type". Nothing else changes: the
  pages are generic over the entry (`AshEnterpriseWeb.ArtifactLive`), and a link to a
  version is `path/2`.

  ## Reading is always as the viewer

  Every read here goes through the resource's own policies with the viewer's actor and
  tenant, behind the entry's door (`AshEnterprise.Surfaces.Doors`). Every entry names its
  door; most are `:signed_in`. A version the viewer may not read is `:unreadable`,
  which the pages never show as missing, unchanged or valid.
  """

  use AshVersions.Registry
  use Gettext, backend: AshEnterpriseWeb.Gettext

  require Ash.Query

  alias AshEnterprise.Accounts
  alias AshEnterprise.Artifacts.{Differs, Facets}
  alias AshEnterprise.Audit.EventLog
  alias AshEnterprise.Security.ActorContext
  alias AshEnterprise.Surfaces.Doors
  alias AshVersions.Artifact

  @status_lifecycle %{draft: :draft, published: :current, retired: :past}

  @artifacts [
    %Artifact{
      type: :agent,
      label: dgettext_noop("artifacts", "Agent version"),
      resource: AshEnterprise.Execution.AgentVersion,
      identity: :key,
      version: :version,
      lineage: [key: :key, order: :version],
      lifecycle: {:status, @status_lifecycle},
      scope: :tenant,
      content_hash: :content_hash,
      parent: :baseline_id,
      published: [:apply_publish],
      references: &Facets.agent_references/1,
      validate: &Facets.agent_problems/1,
      differ: Differs.AgentVersion,
      runs: {AshEnterprise.Execution.Run, :agent_version_id},
      door: :signed_in
    },
    %Artifact{
      type: :process,
      label: dgettext_noop("artifacts", "Process definition"),
      resource: AshEnterprise.Bpmn.Definition,
      identity: :key,
      version: :version,
      lineage: [key: :key, order: :version],
      lifecycle: {:status, @status_lifecycle},
      scope: :tenant,
      content_hash: :content_hash,
      published: [:publish],
      references: &Facets.process_references/1,
      validate: &Facets.process_problems/1,
      differ: Differs.Process,
      door: :signed_in
    },
    %Artifact{
      type: :decision,
      label: dgettext_noop("artifacts", "Decision definition"),
      resource: AshEnterprise.Decisions.Definition,
      identity: :key,
      version: :version,
      lineage: [key: :key, order: :version],
      lifecycle: {:status, @status_lifecycle},
      scope: :tenant,
      content_hash: :content_hash,
      published: [:publish],
      references: &Facets.decision_references/1,
      validate: &Facets.decision_problems/1,
      differ: Differs.Decision,
      door: :signed_in
    },
    %Artifact{
      type: :mapping,
      label: dgettext_noop("artifacts", "Schema mapping"),
      resource: AshEnterprise.Mdm.Mapping,
      identity: :stream,
      version: :version,
      lineage: [key: :root_id, order: :version],
      lifecycle: {:status, %{draft: :draft, validated: :draft, active: :current, retired: :past}},
      scope: :tenant,
      content_hash: :content_hash,
      published: [:activate],
      references: &Facets.mapping_references/1,
      validate: &Facets.mapping_problems/1,
      differ: Differs.Mapping,
      door: :operator
    },
    %Artifact{
      type: :suite,
      label: dgettext_noop("artifacts", "Evaluation suite"),
      resource: AshEnterprise.Quality.Suite,
      identity: :key,
      version: :version,
      lineage: [key: :key, order: :version],
      lifecycle: {:status, @status_lifecycle},
      scope: :tenant,
      content_hash: :content_hash,
      published: [:publish],
      validate: &Facets.suite_problems/1,
      differ: Differs.Suite,
      door: :signed_in
    },
    %Artifact{
      type: :release,
      label: dgettext_noop("artifacts", "Release manifest"),
      resource: AshEnterprise.Execution.ReleaseManifest,
      identity: :key,
      version: :version,
      lineage: [key: :key, order: :version],
      lifecycle:
        {:status,
         %{
           draft: :draft,
           resolved: :draft,
           requested: :draft,
           active: :current,
           superseded: :past,
           rolled_back: :past
         }},
      scope: :tenant,
      content_hash: :manifest_digest,
      published: [:promote],
      references: &Facets.release_references/1,
      validate: &Facets.release_problems/1,
      differ: Differs.ReleaseManifest,
      door: :signed_in
    },
    %Artifact{
      type: :rule_set,
      label: dgettext_noop("artifacts", "Rule set"),
      resource: AshCompliance.Resources.RuleSetRevision,
      identity: :name,
      version: :revision,
      lineage: [key: :name, order: :inserted_at],
      lifecycle:
        {:status,
         %{
           draft: :draft,
           validated: :draft,
           approved: :draft,
           active: :current,
           retired: :past,
           revoked: :past
         }},
      scope: {:attribute, :organization_id},
      content_hash: :content_hash,
      published: [:activate],
      references: &Facets.rule_set_references/1,
      differ: Differs.RuleSet,
      door: :compliance
    },
    %Artifact{
      type: :surface,
      label: dgettext_noop("artifacts", "Saved surface"),
      resource: AshEnterprise.Assistant.PinnedApp,
      identity: :title,
      # The person's own: the resource's policies keep the rows to their owner.
      scope: :tenant,
      published: [:pin],
      references: &Facets.surface_references/1,
      validate: &Facets.surface_problems/1,
      differ: Differs.SurfaceSpec,
      door: :signed_in
    }
  ]

  # --- the host's side of the registry ----------------------------------------------

  @impl true
  def artifacts, do: @artifacts

  @impl true
  def tenant(actor), do: ActorContext.tenant(actor)

  @impl true
  def open?(door, actor), do: Doors.open?(door, actor)

  @doc "A registry label in the viewer's locale."
  @impl true
  @spec translate(String.t()) :: String.t()
  def translate(text), do: Gettext.dgettext(AshEnterpriseWeb.Gettext, "artifacts", text)

  @doc """
  Who published `record`: the person on the newest audit event of one of the entry's
  `published` actions, `:not_recorded` when there is none, or `:unreadable` when the viewer
  may not read the audit trail.
  """
  @impl true
  def publisher(%Artifact{resource: resource, published: actions}, record, actor) do
    tenant = ActorContext.tenant(actor)

    # A reader without the audit grant would read no events, which is not "none
    # recorded": the audit door (a read grant on the log, precomputed) is asked first.
    with true <- Doors.open?(:audit, actor),
         {:ok, events} <-
           EventLog
           |> Ash.Query.for_read(:read, %{}, actor: actor, tenant: tenant)
           |> Ash.Query.filter(
             resource == ^resource and record_id == ^record.id and action in ^actions
           )
           |> Ash.Query.sort(occurred_at: :desc)
           |> Ash.Query.limit(1)
           |> Ash.read() do
      case events do
        [%{user_id: nil}] -> {:ok, dgettext("artifacts", "the system")}
        [%{user_id: user_id}] -> {:ok, person(user_id, actor)}
        [] -> :not_recorded
      end
    else
      _forbidden -> :unreadable
    end
  end

  defp person(id, actor) do
    case Accounts.get_user(id, actor: actor, tenant: ActorContext.tenant(actor)) do
      {:ok, user} -> to_string(user.email)
      {:error, _not_readable} -> "person:#{id}"
    end
  end

  @doc "The web path of one version: its header, validation and diff."
  @spec path(Artifact.t() | atom(), Ash.UUID.t()) :: String.t()
  def path(%Artifact{type: type}, id), do: path(type, id)
  def path(type, id) when is_atom(type), do: "/app/artifacts/#{type}/#{id}"
end
