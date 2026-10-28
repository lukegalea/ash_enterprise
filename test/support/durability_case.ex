defmodule AshEnterprise.DurabilityCase do
  @moduledoc """
  The case template for the durability tier: tests that commit for real, on a database of
  their own, with a real Oban.

      defmodule AshEnterprise.Durability.ClaimTest do
        use AshEnterprise.DurabilityCase, async: false
        ...
      end

  Every test in a module using this is tagged `:durability`, so the ordinary `mix test` run
  excludes it, and it runs only under `mix test.durability` (docs/DURABILITY-TESTS.md). Run in
  the ordinary suite by `--only durability`, it fails at once with that instruction instead of
  running against the sandbox it was written to avoid.

  Nothing is rolled back. Key every row a test writes by something unique to that test.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      @moduletag :durability

      use ExUnitProperties

      import AshEnterprise.Durability

      alias AshEnterprise.Durability.Interleavings
      alias AshEnterprise.Faults
      alias AshEnterprise.Repo
    end
  end

  setup_all do
    unless AshEnterprise.Durability.enabled?() do
      raise """
      durability tests run only in the durability tier, which needs its own database and a real
      Oban. Run them with:

          mix test.durability [files]

      (see docs/DURABILITY-TESTS.md)
      """
    end

    :ok
  end

  setup do
    on_exit(&AshEnterprise.Faults.disarm_all/0)
  end
end
