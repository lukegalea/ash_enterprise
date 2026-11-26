defmodule Battery.Domain do
  @moduledoc """
  The battery's reference domain: every substrate resource the scenarios
  instantiate, declared the way a host declares them — on the battery's own
  base, its own repo, its own policies.
  """

  use Ash.Domain, validate_config_inclusion?: false

  resources do
    # The AshEvents audit log the judgment-side writes land in.
    resource Battery.Events.EventLog

    # The compliance plane's own event log.
    resource Battery.Compliance.EventLog

    # A hash-chained audit log with its archive and run ledger (ash_events_chain), and the
    # evidence archive (ash_compliance) whose moves share that ledger.
    resource Battery.Audit.EventLog
    resource Battery.Audit.ArchivedEvent
    resource Battery.Audit.ArchiveRun
    resource Battery.Compliance.ArchivedEvidence

    # System One (ash_judgments fragments on the battery's base).
    resource Battery.SystemOne.CaseFile
    resource Battery.SystemOne.Judgment
    resource Battery.SystemOne.Fact
    resource Battery.SystemOne.Banding

    # Decisions (ash_decisions resource macros).
    resource Battery.Decisions.Definition
    resource Battery.Decisions.Evaluation

    # Processes (ash_bpmn resource macros + a host subject).
    resource Battery.Bpmn.Definition
    resource Battery.Bpmn.Instance
    resource Battery.Bpmn.Token
    resource Battery.Bpmn.HumanTask
    resource Battery.Bpmn.TaskCandidate
    resource Battery.Bpmn.ProcessEvent
    resource Battery.Bpmn.Subject

    # The business-event ledger (ash_discrete_business_events macros).
    resource Battery.BusinessEvents.SourceRecord
    resource Battery.BusinessEvents.Ledger
    resource Battery.BusinessEvents.Ledger.SimulationEvent
    resource Battery.BusinessEvents.MappingVersion
    resource Battery.BusinessEvents.VendorState
    resource Battery.BusinessEvents.SimulatedVendorState

    # Scheduled activation (ash_bpmn timer → ash_compliance dated revision →
    # ash_decisions re-evaluation): the applicants a rule set answers for,
    # and the activation request a process instance runs against.
    resource Battery.Compliance.Applicant
    resource Battery.Compliance.ScheduledActivation

    # Governed invocations (the ash_agent fragment), their target and the people who
    # ask and approve.
    resource Battery.Execution.Member
    resource Battery.Execution.Referral
    resource Battery.Execution.Invocation

    # Declared provider operations (ash_operations): the registry's operations, the
    # submission a governed call acts on, the webhook deliveries it receives and the
    # envelope a follow-up read emits.
    resource Battery.Operations.Registry
    resource Battery.Operations.Submission
    resource Battery.Operations.Delivery
    resource Battery.Operations.ActivationSettled

    # Agent runs (the ash_agent run fragments), and the question an agent asks a person.
    resource Battery.Execution.AgentVersion
    resource Battery.Execution.Run
    resource Battery.Execution.RunFinished
    resource Battery.Execution.Step
    resource Battery.Execution.HumanInput
    resource Battery.Execution.StartProcess

    # MDM (ash_mdm resource macros + a golden entity).
    resource Battery.Mdm.Vendor
    resource Battery.Mdm.Mapping
    resource Battery.Mdm.MatchRuleSet
    resource Battery.Mdm.MatchCandidate

    # Canonical sources (ash_strangler) and the facades: the temporal task and
    # the audited credential are owned rows; the card renames the credential's
    # words and lets the source's field policy decide; the work-item renames
    # the task's words and writes one source action per write, and the row
    # reads the work-item — a two-hop chain, read hop by hop.
    resource Battery.Canonical.Task
    resource Battery.Canonical.Credential
    resource Battery.Canonical.CredentialCard
    resource Battery.Canonical.WorkItem
    resource Battery.Canonical.WorkItemRow
  end
end
