defmodule AshEnterprise.AgentGateRulesTest do
  @moduledoc """
  AST-77: this repository's pre-flight gate rules
  (`priv/decisions/agent_gate_rules.dmn`, asked before ash_agent_tools'
  generic seed) say what CLAUDE.md and the ship-a-change skill say, and no
  more: each rule's refusing side and the legitimate work beside it.

  The requests run against a synthetic repository whose remote and
  `.agents/gate.json` are this repository's own, so classification is the
  real one; the tables are evaluated dry (no `Evaluation` row).
  """

  use ExUnit.Case, async: true

  alias AshAgentTools.Gate

  @root Path.expand("../..", __DIR__)
  @host_table Path.join(@root, "priv/decisions/agent_gate_rules.dmn")

  setup_all do
    dir = Path.join(System.tmp_dir!(), "agent_gate_rules_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, ".agents"))
    {_, 0} = System.cmd("git", ["init", "-q", dir])

    {_, 0} =
      System.cmd("git", [
        "-C",
        dir,
        "remote",
        "add",
        "origin",
        "https://github.com/lukegalea/ash_enterprise.git"
      ])

    File.cp!(Path.join(@root, ".agents/gate.json"), Path.join(dir, ".agents/gate.json"))
    on_exit(fn -> File.rm_rf!(dir) end)

    tables = [@host_table, Gate.seed_table()]

    # The evaluator gives each table one second; the first evaluation also
    # compiles the tables and loads the FEEL modules, which a loaded host can
    # stretch past that. Pay for both once, as the daemon does at start.
    assert Gate.warm(root: dir, tables: tables) == []
    Gate.explain(%{"tool" => "Bash", "command" => "ls", "cwd" => dir}, root: dir, tables: tables)

    %{dir: dir, tables: tables}
  end

  defp bash(ctx, command) do
    %{"tool" => "Bash", "command" => command, "cwd" => ctx.dir}
    |> Gate.explain(root: ctx.dir, tables: ctx.tables)
    |> then(&{&1.decision, &1.rule_id})
  end

  defp edit(ctx, path) do
    %{"tool" => "Edit", "paths" => [path], "cwd" => ctx.dir}
    |> Gate.explain(root: ctx.dir, tables: ctx.tables)
    |> then(&{&1.decision, &1.rule_id})
  end

  test "the tables pass the ash_decisions verifier: complete, nothing undecided", ctx do
    report = Gate.verify(tables: ctx.tables)

    assert report.ok?, inspect(report, pretty: true)
    assert Enum.all?(report.tables, &(&1.obligations == []))
  end

  test "each rule cites the line it comes from" do
    xml = File.read!(@host_table)

    for [rule, description] <-
          Regex.scan(~r/<rule id="(\w+)">\s*<description>([^<]+)</, xml, capture: :all_but_first),
        rule != "ae_no_rule" do
      assert description =~ ~r/(CLAUDE\.md|SKILL\.md):\d+/, "#{rule} cites no source line"
    end
  end

  test "this repository is first-party; the seed sees through to forks", ctx do
    assert Gate.explain(%{"tool" => "Bash", "command" => "ls", "cwd" => ctx.dir}, root: ctx.dir).request.repo.kind ==
             "first_party"
  end

  describe "ae_ci_force_push" do
    test "force-pushing your own ci/ branch is allowed", ctx do
      assert bash(ctx, "git push -f origin HEAD:refs/heads/ci/s1-l6b") ==
               {"allow", "ae_ci_force_push"}

      assert bash(ctx, "git -C #{ctx.dir} push --force origin HEAD:refs/heads/ci/x") ==
               {"allow", "ae_ci_force_push"}
    end

    test "force to main, to any other branch, or inside a compound command is denied", ctx do
      for command <- [
            "git push -f origin HEAD:refs/heads/main",
            "git push --force origin HEAD:main",
            "git push -f origin feature",
            "git push -f origin HEAD:refs/heads/ci/x && git push -f origin main"
          ] do
        assert bash(ctx, command) == {"deny", "gate_force_push"}, command
      end
    end

    test "a -C directory the shell would compute never rides the allow", ctx do
      for command <- [
            "git -C $(git${IFS}push${IFS}-f${IFS}origin${IFS}main) push -f origin HEAD:refs/heads/ci/x",
            "git -C $(echo${IFS}$HOME/fork) push -f origin HEAD:refs/heads/ci/x",
            "git -C `pkill${IFS}-f${IFS}beam` push -f origin HEAD:refs/heads/ci/x",
            "git -C $HOME/$(id) push -f origin HEAD:refs/heads/ci/x"
          ] do
        assert bash(ctx, command) == {"deny", "gate_force_push"}, command
      end
    end

    test "a plain push to main and deleting your ci/ branch are left to the harness", ctx do
      assert bash(ctx, "git push origin HEAD:refs/heads/main") == {"defer", "gate_no_rule"}
      assert bash(ctx, "git push origin --delete ci/s1-l6b") == {"defer", "gate_no_rule"}
    end
  end

  describe "ae_ecto_drop_shared and ae_ecto_drop_own" do
    test "dropping or resetting without DB_NAME is denied", ctx do
      assert bash(ctx, "devenv shell -- mix ecto.drop") == {"deny", "ae_ecto_drop_shared"}
      assert bash(ctx, "devenv shell -- mix ecto.reset") == {"deny", "ae_ecto_drop_shared"}
    end

    test "dropping a database the command names is asked", ctx do
      command = "devenv shell -- bash -lc 'export DB_NAME=ash_enterprise_s1x && mix ecto.drop'"
      assert bash(ctx, command) == {"ask", "ae_ecto_drop_own"}
    end

    test "migrating is not dropping", ctx do
      assert bash(ctx, "devenv shell -- mix ecto.migrate") == {"defer", "gate_no_rule"}
    end
  end

  describe "ae_bare_mix" do
    test "mix outside devenv is denied", ctx do
      for command <- [
            "mix test",
            "MIX_ENV=test mix compile",
            "cd lib && mix format",
            "timeout 60 mix test",
            "echo devenv shell; mix test",
            "ls\nmix test",
            "devenv shell -- bash -lc 'cd wt' && mix test"
          ] do
        assert bash(ctx, command) == {"deny", "ae_bare_mix"}, command
      end
    end

    test "mix inside devenv shell is allowed through", ctx do
      for command <- [
            "devenv shell -- mix test test/a_test.exs",
            "cd ~/ash_enterprise && devenv shell -- bash -lc 'cd wt && mix credo --strict'",
            "echo mix test",
            ~s(devenv shell -- bash -lc "cd wt && mix test"),
            "git commit -m \"$(cat <<'EOF'\nA fix\n\nmix test passes\nEOF\n)\""
          ] do
        assert bash(ctx, command) == {"defer", "gate_no_rule"}, command
      end
    end
  end

  describe "ae_phx_server" do
    test "phx.server inside devenv asks; iex-server does not", ctx do
      assert bash(ctx, "devenv shell -- mix phx.server") == {"ask", "ae_phx_server"}
      assert bash(ctx, "devenv shell -- iex-server") == {"defer", "gate_no_rule"}
    end
  end

  describe "ae_vendored_cdm" do
    test "editing the vendored CDM corpus is denied; its attribution file is not", ctx do
      assert edit(ctx, "priv/cdm/schemaDocuments/x.json") == {"deny", "ae_vendored_cdm"}

      assert edit(ctx, Path.join(ctx.dir, "priv/cdm/schemaDocuments/core/a.json")) ==
               {"deny", "ae_vendored_cdm"}

      assert edit(ctx, "priv/cdm/ATTRIBUTION.md") == {"defer", "gate_no_rule"}
    end
  end

  describe "ae_generated_migration" do
    test "hand-editing a migration or a snapshot is denied; resources are not", ctx do
      assert edit(ctx, "priv/repo/migrations/20260101000000_x.exs") ==
               {"deny", "ae_generated_migration"}

      assert edit(ctx, "priv/resource_snapshots/repo/x/1.json") ==
               {"deny", "ae_generated_migration"}

      assert edit(ctx, "lib/ash_enterprise/accounts/user.ex") == {"defer", "gate_no_rule"}
    end
  end

  describe "ae_agents_md" do
    test "editing AGENTS.md asks; CLAUDE.md does not", ctx do
      assert edit(ctx, "AGENTS.md") == {"ask", "ae_agents_md"}
      assert edit(ctx, "CLAUDE.md") == {"defer", "gate_no_rule"}
    end
  end

  describe "the seed's rules, through this repository's table" do
    test "killing by pattern and skipping hooks are denied", ctx do
      assert bash(ctx, "pkill -f phx.server") == {"deny", "gate_kill_by_pattern"}
      assert bash(ctx, "killall beam.smp") == {"deny", "gate_kill_by_pattern"}
      assert bash(ctx, "git commit --no-verify -m x") == {"deny", "gate_no_verify"}
      assert bash(ctx, "kill 4242") == {"defer", "gate_no_rule"}
    end
  end
end
