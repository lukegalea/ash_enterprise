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

  @switches [org: :string]

  @impl Mix.Task
  def run(args) do
    {opts, _} = OptionParser.parse!(args, strict: @switches)
    Mix.Task.run("app.start")

    organization_id = opts[:org] || AshEnterprise.Legacy.Estate.organization_id()

    AshEnterprise.Compliance.Seeds.seed(organization_id)
  end
end
