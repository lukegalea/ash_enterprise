defmodule AshEnterprise.Execution.StartProcess do
  @moduledoc """
  An agent starts a process (ADR 0055, ADR 0056): the `start_process` tool.

  The tool is a governed target like any other tool call that is not an in-loop read, so
  the call is one `AshEnterprise.Execution.Invocation`. It asks a person to confirm first
  (`approval: :confirm`): until they do there is no instance, and once they do there is
  exactly one. The target writes only to this application, so it runs inline with the
  invocation's own completion, in one transaction, under the invocation's key: a
  redelivery gets the recorded answer and starts nothing.

  Only a process on the allowlist (`AshEnterprise.Process.StartableKey`) may be named, and
  the person's own policies decide whether the record it is about is theirs to start work
  for. The instance runs the definition the tenant runs now
  (`AshEnterprise.Process.Resolver`), pinned for its life, and under the active release
  manifest that names its process when there is one
  (`AshEnterprise.Bpmn.Changes.PinReleaseManifest`). The person the agent acts for is
  its starter, so what its service tasks do runs as them.

  Self-service (ADR 0052): any member may ask, through their own run.
  """

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Execution,
    data_layer: Ash.DataLayer.Simple,
    ownership: :none,
    tenant?: false,
    lifecycle?: false,
    archival?: false,
    audit?: false,
    self_service: [:start],
    extra_extensions: [AshAgent.Effects]

  resource do
    require_primary_key? false
  end

  # Starting writes only here, and asking again under the same invocation starts no second
  # instance, so a retry is safe. Not destructive: nothing it does is undone by being
  # approved wrongly except by cancelling the instance.
  effects do
    action :start,
      kind: :execute,
      destructive?: false,
      idempotent?: true,
      open_world?: false,
      approval: :confirm,
      intent: :execute
  end

  actions do
    action :start, :map do
      description """
      Start a process on a record, for the person you act for. Only processes your
      organization lets agents start may be named; the person confirms before it starts.
      """

      argument :process, AshEnterprise.Process.StartableKey do
        allow_nil? false
        description "The key of the process to start."
      end

      argument :subject_type, :string do
        allow_nil? false
        constraints max_length: 255
        description "The record's resource, as its module name."
      end

      argument :subject_id, :uuid do
        allow_nil? false
        description "The id of the record the process is about."
      end

      run AshEnterprise.Execution.Actions.StartProcess
    end
  end
end
