defmodule Battery.Execution.StartProcess do
  @moduledoc """
  An agent's `start_process` tool: starts a process on a record, for the person the run
  acts for, who confirms first (`approval: :confirm`). Only a key on the allowlist
  (`Battery.Execution.StartableKey`) may be named. It writes only here, so it runs inline
  with its invocation's completion, in one transaction: until it is approved there is no
  instance, and once it is there is one, started by that person.
  """

  use Ash.Resource,
    domain: Battery.Domain,
    extensions: [AshAgent.Effects]

  effects do
    action :start,
      kind: :execute,
      destructive?: false,
      idempotent?: true,
      open_world?: false,
      approval: :confirm,
      intent: :execute
  end

  resource do
    require_primary_key? false
  end

  actions do
    action :start, :map do
      description "Start a process on a record, for the person you act for."
      argument :process, Battery.Execution.StartableKey, allow_nil?: false
      argument :subject_id, :uuid, allow_nil?: false

      run fn input, context ->
        %{process: key, subject_id: id} = input.arguments

        with {:ok, subject} <- Ash.get(Battery.Execution.Referral, id),
             {:ok, instance} <-
               AshBpmn.start_instance(Battery.Domain,
                 process: key,
                 subject: subject,
                 started_by_id: context.actor.id
               ) do
          {:ok, %{"instance_id" => instance.id, "process" => key}}
        end
      end
    end
  end
end
