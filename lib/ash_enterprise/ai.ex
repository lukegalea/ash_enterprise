defmodule AshEnterprise.AI do
  @moduledoc """
  The agent-facing domain: interpretation only.

  It holds exactly one action, and that action returns a value rather than
  changing anything. That is the whole design — see
  `docs/manifesto/05-agents-are-users.md`. Mutations proposed by an agent are
  executed by `AshEnterprise.AI.Proposal` with the approving human as the actor,
  through the same policies as every other caller.

  No resources, no tables. This domain exists so that a prompt-backed action can
  live somewhere sensible, not because "AI" is a part of the domain model.
  """

  use Ash.Domain, otp_app: :ash_enterprise, validate_config_inclusion?: false

  resources do
    # No tables. RequestClassifier exists only to give the prompt-backed action
    # a home, because Ash puts generic actions on resources rather than domains.
    resource AshEnterprise.AI.RequestClassifier
  end

  @doc """
  The model used for interpretation.

  Configurable so a deployment can choose its provider and tier without editing
  the action. This is a classification task over short text, so a small fast
  model is the right default -- the expensive reasoning in this flow is done by
  the human reading the confirmation.
  """
  def model do
    Application.get_env(:ash_enterprise, :ai)[:interpreter_model] ||
      "anthropic:claude-haiku-4-5-20251001"
  end
end
