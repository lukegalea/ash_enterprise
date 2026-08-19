defmodule AshEnterprise.Bpmn.Token do
  @moduledoc """
  One live branch of a running process.

  **Not audited, deliberately.** A token is the engine's own bookkeeping: it is created,
  claimed, consumed and killed several times per node, and auditing that would add thousands
  of rows per instance saying nothing that `AshEnterprise.Bpmn.ProcessEvent` does not already
  say in the vocabulary a person reads. Two logs that overlap will eventually disagree, and
  the one an auditor opens will be the wrong one.
  """

  use AshBpmn.Resources.Token,
    domain: AshEnterprise.Bpmn,
    repo: AshEnterprise.Repo,
    table: "bpmn_tokens",
    instance: AshEnterprise.Bpmn.Instance,
    base: AshEnterprise.Platform.Resource,
    base_opts: [
      ownership: :organization_owned,
      lifecycle?: false,
      audit?: false,
      archival?: false
    ]
end
