defmodule AshEnterprise.AI do
  @moduledoc """
  The agent-facing domain: interpretation only.

  It holds exactly one action, and that action returns a value rather than
  changing anything. That is the whole design — see
  `docs/manifesto/05-agents-are-users.md`. Mutations proposed by an agent are
  executed by `AshEnterprise.AI.Proposal` with the approving human as the actor,
  through the same policies as every other caller.

  One table: `AshEnterprise.AI.ModelCall`, the append-only record of every
  model call (ADR 0042's flow record, written by `AshEnterprise.AI.Models`).
  Otherwise this domain exists so that a prompt-backed action can live
  somewhere sensible, not because "AI" is a part of the domain model.
  """

  use Ash.Domain, otp_app: :ash_enterprise

  resources do
    # No table. RequestClassifier exists only to give the prompt-backed action
    # a home, because Ash puts generic actions on resources rather than domains.
    resource AshEnterprise.AI.RequestClassifier
    resource AshEnterprise.AI.ModelCall
  end

  @doc """
  The model used for interpretation.

  Configurable so a deployment can choose its provider and tier without editing
  the action. This is a classification task over short text, so a small fast
  model is the right default -- the expensive reasoning in this flow is done by
  the human reading the confirmation.

  An explicit `AI_INTERPRETER_MODEL` wins; otherwise the in-zone generative
  profile when one is configured (`S1_GEN_BASE_URL` + `S1_GEN_MODEL`), otherwise
  a small hosted model. See `AshEnterprise.AI.Models`.
  """
  def model, do: AshEnterprise.AI.Models.interpreter_spec()
end
