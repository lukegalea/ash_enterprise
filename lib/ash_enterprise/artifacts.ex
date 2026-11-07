defmodule AshEnterprise.Artifacts do
  @moduledoc """
  The artifact registry: every versioned thing a person authors, reviews or releases,
  declared once, a sibling of `AshEnterprise.Surfaces`.

  An entry (`AshEnterprise.Artifacts.Artifact`) names a resource and what the artifact
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
  `AshEnterprise.Artifacts.Differ` named in `differ:`. Its `aspects/0` says what it
  compares; its `diff/3` compares by meaning (graph nodes, cases, tools), never by text.
  A type with no differ shows "no semantic diff for this type". Nothing else changes: the
  pages are generic over the entry (`AshEnterpriseWeb.ArtifactLive`), and a link to a
  version is `path/2`.

  ## Reading is always as the viewer

  Every read here goes through the resource's own policies with the viewer's actor and
  tenant, behind the entry's door. A version the viewer may not read is `:unreadable`,
  which the pages never show as missing, unchanged or valid.
  """

  use Gettext, backend: AshEnterpriseWeb.Gettext

  require Ash.Query

  import Ash.Expr, only: [expr: 1, ref: 1]

  alias AshEnterprise.Accounts
  alias AshEnterprise.Artifacts.{Artifact, Change, Differs, Facets}
  alias AshEnterprise.Audit.EventLog
  alias AshEnterprise.Security.ActorContext
  alias AshEnterprise.Surfaces.Doors

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
      runs: {AshEnterprise.Execution.Run, :agent_version_id}
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
      differ: Differs.Process
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
      differ: Differs.Decision
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
      differ: Differs.Suite
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
      differ: Differs.ReleaseManifest
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
      scope: :organization,
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
      scope: :owner,
      published: [:pin],
      references: &Facets.surface_references/1,
      validate: &Facets.surface_problems/1,
      differ: Differs.SurfaceSpec
    }
  ]

  @by_type Map.new(@artifacts, &{&1.type, &1})
  @by_name Map.new(@artifacts, &{Atom.to_string(&1.type), &1})
  @recent 20

  @type state ::
          {:changes, [Change.t()]}
          | {:unchanged, :same_content | :compared}
          | :uncovered
          | :no_differ
          | :first
          | :unchained
          | {:unreadable, :from}
          | {:failed, term()}

  # --- the registry -----------------------------------------------------------------

  @doc "Every artifact type, in registry order."
  @spec all() :: [Artifact.t()]
  def all, do: @artifacts

  @doc "The entry for `type` (an atom or its name), or `nil`."
  @spec fetch(atom() | String.t() | nil) :: Artifact.t() | nil
  def fetch(type) when is_atom(type), do: Map.get(@by_type, type)
  def fetch(name) when is_binary(name), do: Map.get(@by_name, name)

  @doc "The entry whose versions are rows of `resource`, or `nil`."
  @spec for_resource(module()) :: Artifact.t() | nil
  def for_resource(resource), do: Enum.find(@artifacts, &(&1.resource == resource))

  @doc "The web path of one version: its header, validation and diff."
  @spec path(Artifact.t() | atom(), Ash.UUID.t()) :: String.t()
  def path(%Artifact{type: type}, id), do: path(type, id)
  def path(type, id) when is_atom(type), do: "/app/artifacts/#{type}/#{id}"

  @doc "A registry label in the viewer's locale."
  @spec translate(String.t()) :: String.t()
  def translate(text), do: Gettext.dgettext(AshEnterpriseWeb.Gettext, "artifacts", text)

  @doc "What `entry`'s differ compares, as `[{aspect, label}]`; `[]` with no differ."
  @spec aspects(Artifact.t()) :: [{atom(), String.t()}]
  def aspects(%Artifact{differ: nil}), do: []
  def aspects(%Artifact{differ: differ}), do: differ.aspects()

  # --- reading, as the viewer -------------------------------------------------------

  @doc """
  Every type the viewer's doors admit, each with its newest versions the viewer may read:
  `[%{artifact:, items: {:ok, [record]} | {:error, reason}}]`.
  """
  @spec discover(term()) :: [
          %{artifact: Artifact.t(), items: {:ok, [struct()]} | {:error, term()}}
        ]
  def discover(actor) do
    for entry <- @artifacts, Doors.open?(entry.door, actor) do
      %{artifact: entry, items: list(entry, actor)}
    end
  end

  @doc "The newest versions of `entry` the viewer may read, or `{:error, reason}`."
  @spec list(Artifact.t(), term(), pos_integer()) :: {:ok, [struct()]} | {:error, term()}
  def list(entry, actor, limit \\ @recent) do
    entry
    |> query(actor)
    |> Ash.Query.sort([{at(entry), :desc}])
    |> Ash.Query.limit(limit)
    |> Ash.read()
  end

  @doc "One version of `entry` by id, read as the viewer, or `:unreadable`."
  @spec get(Artifact.t(), String.t(), term()) :: {:ok, struct()} | :unreadable
  def get(entry, id, actor) do
    with true <- Doors.open?(entry.door, actor),
         {:ok, id} <- Ecto.UUID.cast(id),
         {:ok, %{} = record} <-
           entry |> query(actor) |> Ash.Query.filter(id == ^id) |> Ash.read_one() do
      {:ok, record}
    else
      _unreadable -> :unreadable
    end
  end

  @doc """
  The version `record` follows: `{:ok, predecessor}`, `:first` when it has none,
  `:unchained` when the type keeps no versions, or `{:unreadable, :from}` when the
  predecessor could not be read.
  """
  @spec previous(Artifact.t(), struct(), term()) ::
          {:ok, struct()} | :first | :unchained | {:unreadable, :from}
  def previous(%Artifact{lineage: nil}, _record, _actor), do: :unchained

  def previous(%Artifact{lineage: lineage} = entry, record, actor) do
    key = Keyword.fetch!(lineage, :key)
    order = Keyword.fetch!(lineage, :order)
    key_value = Map.fetch!(record, key)
    order_value = Map.fetch!(record, order)

    entry
    |> query(actor)
    |> Ash.Query.do_filter(
      expr(^ref(key) == ^key_value and ^ref(order) < ^order_value and id != ^record.id)
    )
    |> Ash.Query.sort([{order, :desc}])
    |> Ash.Query.limit(1)
    |> Ash.read()
    |> case do
      {:ok, [predecessor]} -> {:ok, predecessor}
      {:ok, []} -> first_or_hidden(entry, record, actor)
      {:error, _error} -> {:unreadable, :from}
    end
  end

  # No predecessor the viewer can read: either there is none, or the viewer is not
  # allowed one. Only a version numbered 1 is known to be first; any other is a
  # predecessor the viewer cannot see, never "first".
  defp first_or_hidden(%Artifact{version: version}, record, _actor)
       when not is_nil(version) do
    if Map.get(record, version) in [1, "1"], do: :first, else: {:unreadable, :from}
  end

  defp first_or_hidden(_entry, _record, _actor), do: :first

  @doc """
  What changed between two versions of `entry`. `from` is a record, or the result of
  `previous/3` or `get/3`:

    * `{:changes, changes}`: what the differ found;
    * `{:unchanged, :same_content}`: the differ found nothing and the content hashes
      match; `{:unchanged, :compared}`: it found nothing and there is no hash to check;
    * `:uncovered`: the differ found nothing it covers, but the content hashes differ;
    * `:no_differ`: the type has no semantic diff;
    * `:first`, `:unchained` and `{:unreadable, :from}`: nothing to compare against;
    * `{:failed, reason}`: the differ could not compare, or raised.

  Only `{:unchanged, _}` means "no changes".
  """
  @spec diff(Artifact.t(), term(), struct() | :unreadable, keyword()) :: state()
  def diff(entry, from, to, opts)
  def diff(_entry, _from, :unreadable, _opts), do: {:failed, :unreadable}
  def diff(%Artifact{differ: nil}, _from, _to, _opts), do: :no_differ
  def diff(entry, {:ok, from}, to, opts), do: diff(entry, from, to, opts)
  def diff(_entry, :unreadable, _to, _opts), do: {:unreadable, :from}
  def diff(_entry, {:unreadable, :from} = state, _to, _opts), do: state
  def diff(_entry, state, _to, _opts) when state in [:first, :unchained], do: state

  def diff(
        %Artifact{differ: differ, resource: resource} = entry,
        %{__struct__: resource} = from,
        %{__struct__: resource} = to,
        opts
      ) do
    case differ.diff(from, to, opts) do
      {:ok, [_ | _] = changes} -> {:changes, changes}
      {:ok, []} -> unchanged(entry, from, to)
      {:error, reason} -> {:failed, reason}
      other -> {:failed, {:unexpected, other}}
    end
  rescue
    error -> {:failed, Exception.message(error)}
  end

  def diff(_entry, other, _to, _opts), do: {:failed, {:unexpected, other}}

  defp unchanged(%Artifact{content_hash: nil}, _from, _to), do: {:unchanged, :compared}

  defp unchanged(%Artifact{content_hash: hash}, from, to) do
    case {Map.get(from, hash), Map.get(to, hash)} do
      {same, same} when is_binary(same) -> {:unchanged, :same_content}
      {old, new} when is_binary(old) and is_binary(new) -> :uncovered
      _no_hash -> {:unchanged, :compared}
    end
  end

  @doc """
  `record` checked again: `{:ok, []}` (checked, nothing wrong), `{:ok, problems}`,
  `:undeclared` (the type declares no check) or `{:failed, reason}` (it could not be
  checked). Only `{:ok, []}` is valid.
  """
  @spec validation(Artifact.t(), struct()) ::
          {:ok, [String.t()]} | :undeclared | {:failed, term()}
  def validation(%Artifact{validate: nil}, _record), do: :undeclared

  def validation(%Artifact{validate: validate}, record) do
    case validate.(record) do
      {:ok, problems} when is_list(problems) -> {:ok, Enum.map(problems, &to_string/1)}
      {:error, reason} -> {:failed, reason}
      other -> {:failed, {:unexpected, other}}
    end
  rescue
    error -> {:failed, Exception.message(error)}
  end

  @doc """
  `record`'s lifecycle: `{state, class}`, the class `:draft`, `:current`, `:past` or
  `:unknown` for a state the entry does not name; `nil` when the type has none.
  """
  @spec lifecycle(Artifact.t(), struct()) :: {atom(), Artifact.class()} | nil
  def lifecycle(%Artifact{lifecycle: nil}, _record), do: nil

  def lifecycle(%Artifact{lifecycle: {attribute, classes}}, record) do
    state = Map.get(record, attribute)
    {state, Map.get(classes, state, :unknown)}
  end

  @doc """
  What the header shows of `record`: `%{label, identity, version, lifecycle,
  content_hash, parent, references, published_by}`. `published_by` is `{:ok, name}`,
  `:not_recorded` (no audited publish) or `:unreadable` (the viewer may not read the
  audit trail).
  """
  @spec header(Artifact.t(), struct(), term()) :: map()
  def header(entry, record, actor) do
    %{
      type: entry.type,
      label: translate(entry.label),
      identity: Map.get(record, entry.identity),
      version: entry.version && Map.get(record, entry.version),
      lifecycle: lifecycle(entry, record),
      content_hash: entry.content_hash && Map.get(record, entry.content_hash),
      parent: entry.parent && Map.get(record, entry.parent),
      references: if(entry.references, do: entry.references.(record), else: []),
      published_by: published_by(entry, record, actor)
    }
  end

  @doc """
  Who published `record`: the person on the newest audit event of one of the entry's
  `published` actions.
  """
  @spec published_by(Artifact.t(), struct(), term()) ::
          {:ok, String.t()} | :not_recorded | :unreadable
  def published_by(%Artifact{published: []}, _record, _actor), do: :not_recorded

  def published_by(%Artifact{resource: resource, published: actions}, record, actor) do
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

  @doc """
  Whether the run `run_id` used `record`: `{:this, run}` when it pinned this version,
  `{:other, run}` when it pinned another, `:unreadable` when the run cannot be read, and
  `nil` when there is no run or the type has no runs.
  """
  @spec used_by(Artifact.t(), struct(), String.t() | nil, term()) ::
          {:this | :other, struct()} | :unreadable | nil
  def used_by(_entry, _record, nil, _actor), do: nil
  def used_by(%Artifact{runs: nil}, _record, _run_id, _actor), do: nil

  def used_by(%Artifact{runs: {resource, attribute}}, record, run_id, actor) do
    with {:ok, id} <- Ecto.UUID.cast(run_id),
         {:ok, %{} = run} <-
           resource
           |> Ash.Query.for_read(:read, %{}, actor: actor, tenant: ActorContext.tenant(actor))
           |> Ash.Query.filter(id == ^id)
           |> Ash.read_one() do
      if Map.get(run, attribute) == record.id, do: {:this, run}, else: {:other, run}
    else
      _unreadable -> :unreadable
    end
  end

  defp query(%Artifact{resource: resource, scope: scope}, actor) do
    tenant = ActorContext.tenant(actor)

    resource
    |> Ash.Query.for_read(:read, %{}, actor: actor, tenant: tenant)
    |> scoped(scope, tenant)
  end

  # A type whose rows carry an organization column rather than a data-layer tenant:
  # the tenant's own rows and the ones that hold for every tenant.
  defp scoped(query, :organization, tenant),
    do: Ash.Query.filter(query, is_nil(organization_id) or organization_id == ^tenant)

  defp scoped(query, _scope, _tenant), do: query

  defp at(%Artifact{lineage: [key: _, order: :inserted_at]}), do: :inserted_at

  defp at(%Artifact{resource: resource}) do
    if Ash.Resource.Info.attribute(resource, :created_on), do: :created_on, else: :inserted_at
  end
end
