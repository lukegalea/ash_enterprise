defmodule Mix.Tasks.Ast.Check do
  @shortdoc "Quality gate for the agent-facing surface: action contracts, rules links, manifests"

  @moduledoc """
  Runs this program's own agent-facing tooling as one gate, so the things an
  outside coding agent is told about this repository stay true:

      mix ast.check                        # all steps, human output
      mix ast.check --skip-contracts       # skip the ash_agent_tools smoke test
      mix ast.check --skip-links           # skip the AGENTS.md link check
      mix ast.check --semantic             # also validate priv/semantic manifests
      mix ast.check --format json          # machine-readable report

  Three steps, each skippable, each reporting `ok`, `fail` or `skipped`. Any
  failure exits nonzero, which is what makes this a gate rather than a report.

  ## Contracts (`--skip-contracts` to skip)

  For each `{resource, action, inputs}` triple in
  `config :ash_enterprise, :ast_check_contracts` (see the defaults in this
  module's source), calls `AshAgentTools.describe_action/2` and asserts the
  action still exists and every listed input is still part of its documented
  input contract. A rename that would silently break every agent transcript
  referencing the old name fails here instead of out in the world.

  This step needs `ash_agent_tools`, which is a `only: :dev` path dependency.
  Anywhere else (:test, CI) the step is skipped with a warning rather than
  failing, and the gate still covers the remaining steps.

  ## Rules links (`--skip-links` to skip)

  Every relative markdown link in the composed `AGENTS.md` must resolve to a
  file. `mix usage_rules.sync` links topics into `deps/`, so a package that
  restructures its `usage-rules.md` breaks those links on the next sync — this
  catches it before an agent follows one into a 404.

  ## Semantic manifests (`--semantic`, default off)

  If `priv/semantic/**/*.json` exist, each must parse as JSON, declare
  `manifest_version` `"0"`, and carry symbol ids matching the v0 grammar from
  docs/rfc/semantic-manifest-v0.md §4.3
  (`ash:v0:<module>#<dsl_path>/<name>[:<discriminator>]`). The exporter does
  not exist yet; this step stays off by default until it does, and turns the
  moment manifests appear into the moment they are checked.
  """

  use Mix.Task

  @requirements ["app.start"]

  @switches [
    skip_contracts: :boolean,
    skip_links: :boolean,
    semantic: :boolean,
    format: :string
  ]

  @agents_md "AGENTS.md"
  @semantic_dir "priv/semantic"

  # The v0 symbol-id grammar from docs/rfc/semantic-manifest-v0.md §4.3:
  # `ash:v0:<module>#<dsl_path>/<name>[:<discriminator>]`, where the fragment
  # after `#` is one or more `/`-separated segments (`resource` alone for the
  # resource symbol itself, `actions/name/arguments/name`, `policies/0`,
  # `code_interface/create_team!/3`). Checked at the envelope level: a dotted,
  # capitalized module, then `#`-separated non-empty segments.
  @symbol_id ~r|^ash:v0:[A-Z][A-Za-z0-9_.]*#([^\s#/]+)(/[^\s#/]+)*$|

  # Representative read actions, chosen to exercise the three shapes an agent
  # meets most: a read with required arguments (the audit evidence window), a
  # filtered read behind a domain code interface, and a `get_by` lookup.
  # Overridable — this is the point of the config key:
  #
  #     config :ash_enterprise, :ast_check_contracts,
  #       [%{resource: ..., action: ..., inputs: [...]}]
  @default_contracts [
    %{resource: AshEnterprise.Audit.EventLog, action: :for_export, inputs: [:from, :to]},
    %{resource: AshEnterprise.Process.Binding, action: :for_kind, inputs: [:kind]},
    %{resource: AshEnterprise.Accounts.User, action: :get_by_email, inputs: [:email]}
  ]

  @impl Mix.Task
  def run(argv) do
    {opts, _rest} = OptionParser.parse!(argv, strict: @switches)

    steps = [
      contracts_step(Keyword.get(opts, :skip_contracts, false)),
      rules_links_step(Keyword.get(opts, :skip_links, false)),
      semantic_step(Keyword.get(opts, :semantic, false))
    ]

    report(steps, Keyword.get(opts, :format, "human"))

    if Enum.any?(steps, &(&1.status == :fail)) do
      exit({:shutdown, 1})
    end
  end

  # -- steps -----------------------------------------------------------------

  defp contracts_step(skip?) do
    cond do
      skip? ->
        skipped("contracts", "--skip-contracts")

      not contracts_available?() ->
        skipped(
          "contracts",
          "ash_agent_tools is a dev-only dependency; run with MIX_ENV=dev for this step"
        )

      true ->
        contracts = Application.get_env(:ash_enterprise, :ast_check_contracts, @default_contracts)
        failures = Enum.flat_map(contracts, &check_contract/1)
        finish("contracts", failures, "#{length(contracts)} agent contracts verified")
    end
  end

  defp rules_links_step(skip?) do
    if skip? do
      skipped("rules-links", "--skip-links")
    else
      case rules_link_failures() do
        {:error, message} -> finish("rules-links", [message], "never ran")
        failures -> finish("rules-links", failures, "all AGENTS.md links resolve")
      end
    end
  end

  defp semantic_step(enabled?) do
    cond do
      not enabled? ->
        skipped("semantic", "opt-in via --semantic")

      semantic_manifests() == [] ->
        skipped("semantic", "no manifests under #{@semantic_dir}/ yet")

      true ->
        failures = Enum.flat_map(semantic_manifests(), &check_manifest/1)
        finish("semantic", failures, "#{length(semantic_manifests())} manifests valid")
    end
  end

  # -- contracts -------------------------------------------------------------

  # `runtime: false` and `only: :dev`: rather than crash on a missing module in
  # :test, report the step as skipped and let the other steps gate.
  defp contracts_available? do
    match?({:module, _}, Code.ensure_loaded(AshAgentTools))
  end

  defp check_contract(%{resource: resource, action: action, inputs: inputs}) do
    # Dynamic dispatch on purpose: ash_agent_tools is only: :dev, so under
    # :test (CI's WAE compile) a direct remote call is an undefined-function
    # warning and fails the gate. apply/3 compiles clean everywhere, and
    # check_contract only runs after contracts_available?/0 confirmed the
    # module is loaded. Same pattern ash_enterprise.trace uses for
    # AshAgentTools.Trace.explain/2.
    described = apply(AshAgentTools, :describe_action, [resource, action])

    documented =
      described.input.required
      |> Enum.concat(Enum.map(described.input.optional, & &1.name))
      |> Enum.concat(Enum.map(described.arguments, & &1.name))
      |> MapSet.new()

    case Enum.filter(List.wrap(inputs), &(&1 not in documented)) do
      [] ->
        []

      missing ->
        [
          "#{inspect(resource)}.#{action}: inputs not in the documented contract: #{inspect(missing)}"
        ]
    end
  rescue
    e in ArgumentError ->
      [Exception.message(e)]
  end

  # Tolerate either maps or {resource, action, inputs} triples in the config.
  defp check_contract({resource, action, inputs}) do
    check_contract(%{resource: resource, action: action, inputs: inputs})
  end

  # -- rules links -----------------------------------------------------------

  @link ~r/\]\(([^)\s]+)\)/

  defp rules_link_failures do
    if File.exists?(@agents_md) do
      @agents_md
      |> File.read!()
      |> then(&Regex.scan(@link, &1, capture: :all_but_first))
      |> List.flatten()
      |> Enum.uniq()
      |> Enum.filter(&relative_link?/1)
      |> Enum.reject(&File.exists?(Path.expand(local_path(&1))))
      |> case do
        [] -> []
        broken -> Enum.map(broken, &"#{@agents_md}: broken link -> #{&1}")
      end
    else
      # Not raise: a missing AGENTS.md is a findings list like any other.
      {:error, "#{@agents_md} does not exist"}
    end
  end

  defp relative_link?(target) do
    not Regex.match?(~r|^[a-zA-Z][a-zA-Z0-9+.-]*:|, target) and
      not String.starts_with?(target, "#")
  end

  # Links carry `#fragment` anchors; the fragment names a place in the file,
  # not a file.
  defp local_path(target) do
    target
    |> String.split("#", parts: 2)
    |> hd()
  end

  # -- semantic manifests ----------------------------------------------------

  defp semantic_manifests, do: Path.wildcard("#{@semantic_dir}/**/*.json")

  defp check_manifest(path) do
    case path |> File.read!() |> Jason.decode() do
      {:ok, doc} -> manifest_failures(path, doc)
      {:error, error} -> ["#{path}: invalid JSON: #{Exception.message(error)}"]
    end
  end

  defp manifest_failures(path, %{"manifest_version" => "0", "symbols" => symbols})
       when is_list(symbols) do
    for %{"id" => id} <- symbols,
        is_binary(id),
        not Regex.match?(@symbol_id, id) do
      "#{path}: symbol id does not match the ash:v0 grammar: #{id}"
    end
  end

  defp manifest_failures(path, %{"manifest_version" => version}) when version != "0" do
    ["#{path}: unsupported manifest_version #{inspect(version)}, expected \"0\""]
  end

  defp manifest_failures(path, _doc) do
    ["#{path}: not a v0 semantic manifest (expected manifest_version \"0\" and a symbols array)"]
  end

  # -- reporting -------------------------------------------------------------

  defp finish(name, failures, ok_summary) do
    if failures == [] do
      %{step: name, status: :ok, summary: ok_summary, failures: []}
    else
      %{step: name, status: :fail, summary: "#{length(failures)} problem(s)", failures: failures}
    end
  end

  defp skipped(name, reason) do
    %{step: name, status: :skipped, summary: reason, failures: []}
  end

  defp report(steps, "json") do
    doc = %{
      ok: not Enum.any?(steps, &(&1.status == :fail)),
      steps:
        Enum.map(steps, fn step ->
          %{
            step: step.step,
            status: Atom.to_string(step.status),
            summary: step.summary,
            failures: step.failures
          }
        end)
    }

    Mix.shell().info(Jason.encode!(doc, pretty: true))
  end

  defp report(steps, "human") do
    Enum.each(steps, fn
      %{status: :ok, summary: summary, step: step} ->
        Mix.shell().info("[ok]      #{step}: #{summary}")

      %{status: :fail, summary: summary, step: step, failures: failures} ->
        Mix.shell().error("[FAIL]    #{step}: #{summary}")

        Enum.each(failures, fn failure ->
          Mix.shell().error("          - #{failure}")
        end)

      %{status: :skipped, step: step, summary: reason} ->
        Mix.shell().info("[skipped] #{step}: #{reason}")
    end)

    failed = Enum.count(steps, &(&1.status == :fail))
    Mix.shell().info("ast.check: #{if failed == 0, do: "pass", else: "#{failed} step(s) failed"}")
  end

  defp report(_steps, other) do
    Mix.raise("Unknown --format #{inspect(other)}. Supported formats: human, json.")
  end
end
