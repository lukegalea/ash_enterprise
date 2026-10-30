defmodule AshEnterprise.Test.Execution do
  @moduledoc """
  Test-only domain for the governed-invocation tests' targets. Compiled only in `:test`
  and never registered, so it reaches no migration and no running application.
  """

  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource AshEnterprise.Test.Execution.ClinicNote do
      define :list_notes, action: :read
    end

    resource AshEnterprise.Test.Execution.ReferralBoard
    resource AshEnterprise.Test.Execution.LeakyNote
  end
end
