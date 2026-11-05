defmodule AshEnterprise.EffectsDeclarationTest do
  @moduledoc """
  ADR 0057: every action exposed to an agent or an editor declares its effects
  (`AshAgent.Effects`), and ACP reads those declarations instead of keeping its
  own lists of consequential actions.

  Spark reports verifier errors as compile diagnostics, which is what fails the
  `mix compile --warnings-as-errors` gate CI runs; the compile test below reads
  the diagnostic back from a real compile.
  """

  use ExUnit.Case, async: true

  alias AshAgent.Effects.Info
  alias AshEnterprise.Acp
  alias AshEnterprise.Agents.{Console, MorningBrief}
  alias AshEnterprise.Bpmn.HumanTask
  alias AshEnterprise.Integration.LinkedAccount
  alias AshEnterprise.Security.UserRole

  describe "governed targets" do
    @tag :tmp_dir
    test "an undeclared tool-exposed target fails compilation", %{tmp_dir: tmp_dir} do
      # UserRole carries a governed target (`assign`), so it declares effects,
      # and every action it exposes must be declared. `destroy` is not.
      source = Path.join(tmp_dir, "revoke_tool.ex")

      File.write!(source, """
      defmodule AshEnterprise.EffectsDeclarationTest.RevokeTool do
        use Ash.Domain,
          extensions: [AshAi, AshAgent.Effects.Domain],
          validate_config_inclusion?: false

        resources do
        end

        tools do
          tool :assign_role, AshEnterprise.Security.UserRole, :assign
          tool :revoke_role, AshEnterprise.Security.UserRole, :destroy
        end
      end
      """)

      {{:ok, modules, diagnostics}, _stderr} =
        ExUnit.CaptureIO.with_io(:stderr, fn ->
          Kernel.ParallelCompiler.compile([source], return_diagnostics: true)
        end)

      assert AshEnterprise.EffectsDeclarationTest.RevokeTool in modules

      assert [%{severity: :warning, message: message}] =
               Enum.filter(diagnostics.runtime_warnings, &(&1.message =~ "Spark.Error.DslError"))

      assert message =~
               "tool :revoke_role exposes AshEnterprise.Security.UserRole.destroy, " <>
                 "which has no effects declaration"

      refute message =~ "assign"
    end

    test "assign_role only requests; its governed target declares four-eyes approval" do
      assert %{action: :request_assignment} =
               Enum.find(AshAi.Info.tools(AshEnterprise.Security), &(&1.name == :assign_role))

      assert %{approval: :none, intent: :propose, read_only?: false} =
               Info.effect(UserRole, :request_assignment)

      for action <- [:assign, :assign_governed] do
        assert %{
                 kind: :edit,
                 read_only?: false,
                 open_world?: false,
                 approval: :four_eyes,
                 approver_role: :administrator,
                 intent: :execute
               } = Info.effect(UserRole, action)
      end

      # That only `assign_governed` refuses to run outside its invocation is
      # AshEnterprise.Execution.GovernedTest's.
    end
  end

  describe "what is exposed is declared" do
    test "every domain with ash_ai tools checks them, and every tool's action is declared" do
      domains =
        for domain <- Application.fetch_env!(:ash_enterprise, :ash_domains),
            AshAi in Spark.extensions(domain),
            do: domain

      assert AshEnterprise.Security in domains

      for domain <- domains do
        assert AshAgent.Effects.Domain in Spark.extensions(domain),
               "#{inspect(domain)} exposes ash_ai tools without AshAgent.Effects.Domain"

        for tool <- AshAi.Info.tools(domain) do
          assert Info.declared?(tool.resource, tool.action),
                 "#{inspect(domain)} tool #{inspect(tool.name)} is undeclared"
        end
      end
    end

    test "every action the ACP grammar and palette route to is declared" do
      palette =
        for %{action: {resource, action}} <- AshEnterprise.Surfaces.candidate_actions(),
            do: {resource, action}

      console = for %{name: name} <- Ash.Resource.Info.actions(Console), do: {Console, name}

      for {resource, action} <- Enum.uniq(palette ++ console) do
        assert Info.declared?(resource, action), "#{inspect(resource)}.#{action} is undeclared"
      end
    end
  end

  describe "ACP reads the declarations" do
    test "decisions, syncs and composing a brief ask first, as an execute call" do
      for {resource, action} <- [
            {HumanTask, :approve},
            {HumanTask, :reject},
            {LinkedAccount, :sync_now},
            {MorningBrief, :compose_today}
          ] do
        assert Acp.asks_first?(resource, action), "#{inspect(resource)}.#{action}"
        assert Acp.kind(resource, action) == :execute
      end
    end

    test "the console's digests and one's own action items do not ask" do
      refute Acp.asks_first?(Console, :today)
      assert Acp.kind(Console, :today) == :read
      refute Acp.asks_first?(Console, :todo)
      assert Acp.kind(Console, :todo) == :edit
      refute Acp.asks_first?(Console, :done)
    end

    test "an undeclared write asks first; an undeclared read does not" do
      refute Info.declared?(LinkedAccount, :relabel)
      assert Acp.asks_first?(LinkedAccount, :relabel)
      assert Acp.kind(LinkedAccount, :relabel) == :execute

      refute Info.declared?(LinkedAccount, :mine)
      refute Acp.asks_first?(LinkedAccount, :mine)
      assert Acp.kind(LinkedAccount, :mine) == :read
    end
  end
end
