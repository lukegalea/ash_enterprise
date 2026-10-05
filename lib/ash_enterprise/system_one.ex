defmodule AshEnterprise.SystemOne do
  @moduledoc """
  The System One judgment ledger — the host side of `ash_judgments`
  (AST-88 host wiring).

  A model answer that is not recorded is a rumour, so every judged answer
  lands here as an append-only observation row: the package supplies the
  field contract and the replay-safe actions (`AshJudgments.Ledger.Fragment`,
  `AshJudgments.HumanVerdict.Fragment`), and this domain owns the persisted
  resources on the platform base — which is what makes a judgment auditable
  at all. AshEvents wraps create, update and destroy, never a generic action,
  so the audit rides the ledger's `:record` create: every observation and
  every erasure is an event in `AshEnterprise.Audit.EventLog`, attributed to
  its tenant and correlation group like every other platform write.

  The field/identity contract is the frozen v0 judgment record
  (`docs/rfc/judgment-record-v0.md`, §4–§5); endpoints and keys are never
  recorded (§9) — the model travels as the spec that was requested, and the
  instrument's identity is its digest.

  The ledger resource is registered with the package in `config/runtime.exs`
  (`config :ash_judgments, :ledger`), next to the instrument profiles and the
  residency policy — host configuration, never discovery.
  """

  use Ash.Domain, otp_app: :ash_enterprise

  resources do
    resource AshEnterprise.SystemOne.Judgment
    resource AshEnterprise.SystemOne.HumanVerdict
    resource AshEnterprise.SystemOne.QuestionProposal
    resource AshEnterprise.SystemOne.Banding
    resource AshEnterprise.SystemOne.BandTableCertification
    resource AshEnterprise.SystemOne.Fact
    resource AshEnterprise.SystemOne.CalibrationRun
    resource AshEnterprise.SystemOne.CalibrationSample
    resource AshEnterprise.SystemOne.FilterProposal
    resource AshEnterprise.SystemOne.FilterExecution
  end

  @doc """
  The judge context this host threads into every judge action, carrying the
  platform's attribution through to the recorder (AC-4).

  The package's recorder (`AshJudgments.Ledger.Record`) reads two keys off
  the judge action's plain context map: `:tenant`, which becomes the ledger
  row's tenant (attribute multitenancy — `organization_id`), and
  `:correlation_id`, which is recorded on the row and groups it with every
  other write of the same operation. Neither travels on its own: the tenant
  lives on the action's struct, the correlation id in the process
  dictionary, and AshEvents' audit metadata alone cannot reconstruct a row
  that was written without them. So callers build the context HERE and only
  here:

      input
      |> Ash.run_action(
        actor: actor,
        context:
          AshEnterprise.SystemOne.judge_context(
            tenant: tenant,
            judgments: %{req_llm: req_llm, observation_id: observation_id}
          )
      )

  An omitted correlation id falls back to the ambient one
  (`AshEnterprise.Platform.Correlation.id/0`), so a judge action invoked
  from a request, an Oban job or a test still lands in its operation's
  audit group.
  """
  @spec judge_context(keyword()) :: %{
          required(:tenant) => term(),
          required(:correlation_id) => Ash.UUID.t(),
          required(:judgments) => map()
        }
  def judge_context(opts) do
    %{
      tenant: Keyword.get(opts, :tenant),
      correlation_id:
        Keyword.get(opts, :correlation_id) || AshEnterprise.Platform.Correlation.id(),
      judgments: Keyword.get(opts, :judgments, %{})
    }
  end
end
