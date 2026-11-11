defmodule AshEnterprise.Compliance.ProducerProofTest do
  @moduledoc """
  A producer named in `docs/controls.json` must declare the criteria it
  evidences (`evidence_controls/0`), so a producer that loses its declaration
  fails the suite rather than only the report-mode CI step.

  `file:` producers cannot prove anything: the resolver proves `module:` and
  `mix:` references only. Those rows are expected to be unproven and are named
  below; nothing is invented to silence them.
  """

  use ExUnit.Case, async: true

  alias AshCompliance.Ownership.{Check, Criteria}

  @file_path "docs/controls.json"

  # Rows whose producer is a workflow file, which can never prove a criterion.
  @file_producer_rows ["CC6.8", "CC7.1", "CC8.1"]

  test "every module: and mix: producer declares the criteria that name it" do
    problems =
      Check.run(@file_path,
        categories: Criteria.categories(),
        root: File.cwd!(),
        require_producer_proof: true
      )

    unproven =
      for %{code: :unproven_producer, criterion: id} <- problems, do: id

    assert Enum.sort(unproven) == Enum.sort(@file_producer_rows)
  end
end
