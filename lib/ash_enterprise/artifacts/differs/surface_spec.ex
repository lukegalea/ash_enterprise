defmodule AshEnterprise.Artifacts.Differs.SurfaceSpec do
  @moduledoc """
  Two saved surface specs (`AshEnterprise.Assistant.PinnedApp`), through
  `AshA2ui.Dynamic.diff/2`: components, queries and their presets, fields, actions and
  contexts, matched by name, each with the option that changed. Key order and other
  serialization noise never show.

  Each `AshA2ui.Dynamic.Diff.Change` becomes one change whose aspect is its entity
  (`component`, `query`, `field`, ...) and whose subject is its path.
  """

  @behaviour AshEnterprise.Artifacts.Differ

  use Gettext, backend: AshEnterpriseWeb.Gettext

  alias AshEnterprise.Artifacts.Change

  @impl true
  def aspects do
    [
      surface: dgettext_noop("artifacts", "Surface"),
      component: dgettext_noop("artifacts", "Components"),
      query: dgettext_noop("artifacts", "Queries"),
      preset: dgettext_noop("artifacts", "Presets"),
      field: dgettext_noop("artifacts", "Fields"),
      action: dgettext_noop("artifacts", "Actions"),
      context: dgettext_noop("artifacts", "Contexts"),
      column: dgettext_noop("artifacts", "Columns"),
      group: dgettext_noop("artifacts", "Groups"),
      nested_form: dgettext_noop("artifacts", "Nested forms")
    ]
  end

  @impl true
  def diff(old, new, _opts) do
    diff = AshA2ui.Dynamic.diff(old.spec, new.spec)

    {:ok,
     Enum.map(diff.changes, fn change ->
       %Change{
         aspect: change.entity,
         kind: change.kind,
         subject: change.path,
         option: change.option,
         from: change.from,
         to: change.to
       }
     end)}
  end
end
