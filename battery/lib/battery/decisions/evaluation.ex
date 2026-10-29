defmodule Battery.Decisions.Evaluation do
  @moduledoc """
  The battery's decision-evaluation record: the
  `AshDecisions.Resources.Evaluation` macro bound to the battery's
  Definition. Every evaluation an ash_decisions definition answers is
  recorded here — the identity a banding row's `decision_evaluation_id`
  points back at.
  """

  use AshDecisions.Resources.Evaluation,
    domain: Battery.Domain,
    repo: Battery.Repo,
    definition: Battery.Decisions.Definition

  policies do
    bypass do
      authorize_if always()
    end
  end
end
