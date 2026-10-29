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

    # MDM (ash_mdm resource macros + a golden entity).
    resource Battery.Mdm.Vendor
    resource Battery.Mdm.Mapping
    resource Battery.Mdm.MatchRuleSet
    resource Battery.Mdm.MatchCandidate
  end
end
