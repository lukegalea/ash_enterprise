defmodule AshEnterprise.Test.Execution.ReferralLetters do
  @moduledoc """
  A test-only outside source an agent reads: the letter an outside specialist sent about
  a patient. It reaches outside the application (open-world, the default), so a run that
  reads it takes in text its clinic did not write, and in a run that is not live the
  case's fixtures answer it, which is where an injection case puts its attack.

  Self-service (ADR 0052). A generic action only, no table.
  """

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Test.Execution,
    data_layer: Ash.DataLayer.Simple,
    ownership: :none,
    tenant?: false,
    lifecycle?: false,
    archival?: false,
    self_service: [:read_letter],
    extra_extensions: [AshAgent.Effects]

  resource do
    require_primary_key? false
  end

  effects do
    action :read_letter,
      kind: :fetch,
      destructive?: false,
      idempotent?: true,
      intent: :inspect
  end

  actions do
    action :read_letter, :map do
      argument :patient, :string, allow_nil?: false
      run fn _input, _context -> {:ok, %{"letter" => "SYNTHETIC letter"}} end
    end
  end
end
