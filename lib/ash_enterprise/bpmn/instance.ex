defmodule AshEnterprise.Bpmn.Instance do
  @moduledoc """
  One run of a process, pinned to the definition version it started on.

  Audited: an instance is the record that a process ran at all, and it carries the correlation
  id that joins it to whatever request or event started it.
  """

  use AshBpmn.Resources.Instance,
    domain: AshEnterprise.Bpmn,
    repo: AshEnterprise.Repo,
    table: "bpmn_instances",
    definition: AshEnterprise.Bpmn.Definition,
    base: AshEnterprise.Platform.Resource,
    base_opts: [
      ownership: :organization_owned,
      # `running -> completed | failed | cancelled` is the instance's own state machine.
      lifecycle?: false,
      audit?: true,
      archival?: false
    ]
end
