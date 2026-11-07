defmodule AshEnterprise.Artifacts.Artifact do
  @moduledoc """
  One entry in the artifact registry (`AshEnterprise.Artifacts`): a versioned
  resource, and what the artifact pages need to know about it.

  | Field | Meaning |
  |---|---|
  | `type` | Unique atom, the registry's key and the `/app/artifacts/<type>` segment |
  | `label` | Human name of the type ("Agent version") |
  | `resource` | The Ash resource whose rows are the versions |
  | `identity` | The attribute that names the artifact across its versions (`:key`, `:name`, `:title`) |
  | `version` | The attribute holding the version number or label, or `nil` when the type keeps no versions |
  | `lineage` | How to find a version's predecessor: `[key: attribute, order: attribute]` (the same `key`, the greatest `order` below this one's), or `nil` when versions are not chained |
  | `lifecycle` | `{state_attribute, %{state => class}}`, each class `:draft` (not in use), `:current` (what work uses now) or `:past` (no longer used). A state the map does not name is `:unknown`, never `:current`. `nil` when the type has no lifecycle |
  | `scope` | Where versions live: `:tenant` (the data layer's tenant), `:organization` (an `organization_id` column, `nil` meaning every tenant) or `:owner` (the person's own) |
  | `content_hash` | The attribute holding the content digest, or `nil` |
  | `parent` | The attribute naming the version this one was copied from (`baseline_id`), or `nil` |
  | `published` | The actions whose audit event says who published a version (`[:publish]`) |
  | `references` | `fun(record) -> [{kind, name}]`: what the version names (tools, decisions, a target resource), or `nil` |
  | `validate` | `fun(record) -> {:ok, [problem]} \\| {:error, reason}`: re-checks the stored version, or `nil` when the type declares no check |
  | `differ` | A module implementing `AshEnterprise.Artifacts.Differ`, or `nil`: the type then shows "no semantic diff", never an empty one |
  | `runs` | `{resource, attribute}`: the runs that pin a version by its id, so a page opened from a run can say whether this is the version it used; `nil` when none do |
  | `door` | The surface door the type's versions sit behind (`AshEnterprise.Surfaces.Doors`) |
  """

  @enforce_keys [:type, :label, :resource, :identity, :scope]
  defstruct [
    :type,
    :label,
    :resource,
    :identity,
    :version,
    :lineage,
    :lifecycle,
    :scope,
    :content_hash,
    :parent,
    :references,
    :validate,
    :differ,
    :runs,
    published: [],
    door: :signed_in
  ]

  @type class :: :draft | :current | :past | :unknown

  @type t :: %__MODULE__{
          type: atom(),
          label: String.t(),
          resource: module(),
          identity: atom(),
          version: atom() | nil,
          lineage: [key: atom(), order: atom()] | nil,
          lifecycle: {atom(), %{atom() => class()}} | nil,
          scope: :tenant | :organization | :owner,
          content_hash: atom() | nil,
          parent: atom() | nil,
          published: [atom()],
          references: (struct() -> [{atom(), String.t()}]) | nil,
          validate: (struct() -> {:ok, [String.t()]} | {:error, term()}) | nil,
          differ: module() | nil,
          runs: {module(), atom()} | nil,
          door: AshEnterprise.Surfaces.Surface.door()
        }
end
