# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule Mix.Tasks.AshEnterprise.Compliance.Seed do
  @shortdoc "Seed the KYC compliance program: catalog, rules, profile, waiver, active bundle"

  @moduledoc """
  Seeds the KYC compliance vertical slice (ADR 0035) for the legacy estate's
  tenant. The logic lives in `AshEnterprise.Compliance.Seeds` — the test
  suite's setup calls the same code, so a seeded demo and a seeded test can
  never drift.

      mix ash_enterprise.compliance.seed
      mix ash_enterprise.compliance.seed --org <uuid>   # default: the legacy estate's tenant
  """

  use Mix.Task

  alias AshEnterprise.Mix.Helpers

  @switches [org: :string]

  @requirements ["app.config"]

  @impl Mix.Task
  def run(args) do
    {opts, _} = OptionParser.parse!(args, strict: @switches)

    # Ash writes and reads against the Repo only; the same code is the test
    # suite's setup, which runs without the supervision tree (iron law #23;
    # docs/reviews/iron-law-audit.md, fix item 3).
    Helpers.boot_repo()

    organization_id = opts[:org] || AshEnterprise.Legacy.Estate.organization_id()

    AshEnterprise.Compliance.Seeds.seed(organization_id)
  end
end
