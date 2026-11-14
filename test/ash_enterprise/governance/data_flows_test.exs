defmodule AshEnterprise.Governance.DataFlowsTest do
  @moduledoc """
  The egress register. The coverage check is a grep over `lib/` for a list of
  egress shapes (`DataFlows.primitives/0`): a new HTTP client shape outside the
  list passes unseen until the list grows. Operations declared through
  `AshOperations` are the exception, read from the DSL.
  """
  use ExUnit.Case, async: true

  alias AshEnterprise.Governance.DataFlows

  @root Path.expand("../../..", __DIR__)

  describe "coverage" do
    test "a module in lib/ that calls an egress primitive (Req, ReqLLM, Swoosh delivery, use AshOperations, the lineage transport) and is not in the register fails" do
      # The register as it stands covers every module.
      assert DataFlows.undeclared_modules(root: @root) == []

      # Drop one row and its modules are found, by file and by primitive.
      without = Enum.reject(DataFlows.all(), &(&1.id == :integration_provider_proxy))
      undeclared = DataFlows.undeclared_modules(root: @root, rows: without)

      assert %{module: "AshEnterprise.Integration.Nango.Proxy", primitive: "Req request"} =
               Enum.find(undeclared, &(&1.module == "AshEnterprise.Integration.Nango.Proxy"))

      for {id, module} <- [
            lineage_collector: "AshEnterprise.Lineage.Transport",
            outbound_mail: "AshEnterprise.Mailer",
            model_calls_guarded: "AshEnterprise.AI.Models.GuardedReqLLM",
            design_time_translation: "AshEnterprise.L10n.Translator.ReqLLM"
          ] do
        rows = Enum.reject(DataFlows.all(), &(&1.id == id))
        found = DataFlows.undeclared_modules(root: @root, rows: rows)
        assert Enum.any?(found, &(&1.module == module)), "dropping #{id} should expose #{module}"
      end
    end

    test "a stranger module with an egress call is reported" do
      root = Path.join(System.tmp_dir!(), "data-flows-#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(root, "lib"))

      File.write!(Path.join(root, "lib/stranger.ex"), """
      defmodule Stranger do
        # Req.get("https://example.test") in a comment is not a call.
        def go, do: Req.get!("https://example.test/leak")
      end
      """)

      File.write!(Path.join(root, "lib/quiet.ex"), """
      defmodule Quiet do
        @moduledoc \"\"\"
        Mentions Req.get and Swoosh.Mailer in prose only.
        \"\"\"
        def go, do: :ok
      end
      """)

      try do
        assert [%{module: "Stranger", file: "lib/stranger.ex"}] =
                 DataFlows.undeclared_modules(root: root, rows: [])
      after
        File.rm_rf!(root)
      end
    end

    test "every module a row names exists" do
      for row <- DataFlows.all(), module <- row.modules do
        assert Code.ensure_loaded?(module),
               "#{row.id} names #{inspect(module)}, which is not a module"
      end
    end
  end

  describe "operations" do
    test "every declared ash_operations operation has a register row with a gate" do
      declared =
        for resource <- resources(),
            AshOperations in Spark.extensions(resource),
            operation <- AshOperations.Info.operations(resource),
            do: {inspect(resource), to_string(operation.name)}

      assert declared != []

      rows = DataFlows.operation_rows()

      registered =
        for %{operation: %{resource: resource, name: name}} <- rows, do: {resource, name}

      assert Enum.sort(declared) == Enum.sort(registered)

      for row <- rows do
        assert row.gate == :none or is_map(row.gate), "#{row.id} has no gate field"
      end
    end

    test "a disclosing operation names the resource's disclosure gate and a non-disclosing one says it has none" do
      rows = DataFlows.operation_rows()
      activate = Enum.find(rows, &(&1.operation.name == "activate"))

      assert activate.operation.discloses
      assert activate.gate.enforced_by == AshEnterprise.Credentialing.RegistryDisclosureGate

      reads = Enum.filter(rows, &(not &1.operation.discloses))
      assert reads != []

      for row <- reads do
        assert row.gate == :none
        assert row.known_gap =~ "non-disclosing"
      end
    end
  end

  describe "gates" do
    test "a row whose gate does not govern the path says so (gate: :none or known gap) rather than naming a gate" do
      for row <- DataFlows.all() do
        case row.gate do
          :none ->
            assert is_binary(row.known_gap) and String.length(row.known_gap) > 20,
                   "#{row.id}: gate :none needs a known_gap"

          %{name: name, enforced_by: module} ->
            assert is_binary(name) and name != ""

            assert Code.ensure_loaded?(module),
                   "#{row.id}: gate module #{inspect(module)} does not exist"

          other ->
            flunk("#{row.id}: gate is #{inspect(other)}")
        end
      end

      # The two paths the project knows are open say so.
      by_id = Map.new(DataFlows.all(), &{&1.id, &1})
      assert by_id.integration_provider_proxy.gate == :none
      assert by_id.outbound_mail.gate == :none
      assert by_id.model_calls_guarded.known_gap =~ "sub_processor_opt_in"
    end

    test "rows are well formed" do
      ids = Enum.map(DataFlows.all(), & &1.id)
      assert ids == Enum.uniq(ids)

      for row <- DataFlows.all() do
        assert row.recipient_class
        assert row.data_classes != []
        assert Enum.all?(row.data_classes, &(&1 in DataFlows.data_classes())), "#{row.id}"
      end
    end
  end

  defp resources do
    :ash_enterprise
    |> Application.get_env(:ash_domains, [])
    |> Enum.flat_map(&Ash.Domain.Info.resources/1)
  end
end
