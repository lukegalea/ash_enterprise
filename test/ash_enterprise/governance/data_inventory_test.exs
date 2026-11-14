defmodule AshEnterprise.Governance.DataInventoryTest do
  @moduledoc """
  The generated inventory (docs/data-inventory.json): drift against the
  committed file, classification of personal-looking attributes, global tables
  and the shape of one entry.
  """
  use ExUnit.Case, async: true

  alias AshEnterprise.Governance.DataFlows
  alias AshEnterprise.Governance.DataInventory
  alias Mix.Tasks.AshEnterprise.DataInventory, as: Task

  @root Path.expand("../../..", __DIR__)

  describe "drift" do
    test "a resource registered in a domain but missing from the committed inventory fails --check" do
      committed = @root |> Path.join(Task.path()) |> File.read!() |> Jason.decode!()
      [dropped | rest] = committed["resources"]

      # A file that lacks an entry the code declares is not what the task renders.
      stale = Map.put(committed, "resources", rest)
      refute Task.render(stale) == Task.render()

      names = Enum.map(DataInventory.build()["resources"], & &1["resource"])
      assert dropped["resource"] in names
    end

    test "mix ash_enterprise.data_inventory --check passes on the committed file" do
      assert File.read!(Path.join(@root, Task.path())) == Task.render()

      output = ExUnit.CaptureIO.capture_io(fn -> Task.run(["--check"]) end)
      assert output =~ "is current"
    end
  end

  describe "classification" do
    test "a looks-personal attribute that is neither sensitive?, sealed nor listed with a reason fails" do
      resource = AshEnterprise.Accounts.ProjectedUser
      flagged = %{"resource" => inspect(resource), "attribute" => "email"}

      without = DataInventory.build([resource], %{}, [])
      assert flagged in DataInventory.unclassified(without)

      with_reason = DataInventory.build([resource], DataFlows.looks_personal_exceptions(), [])
      refute flagged in DataInventory.unclassified(with_reason)

      entry = hd(with_reason["resources"])

      assert Enum.find(entry["personal_looking_attributes"], &(&1["attribute"] == "email"))[
               "reason"
             ]
    end

    test "the committed inventory has no unclassified personal-looking attribute" do
      assert DataInventory.unclassified(DataInventory.build()) == []
    end

    test "every exception carries a reason and names an attribute that exists and looks personal" do
      for {{resource, attribute}, reason} <- DataFlows.looks_personal_exceptions() do
        assert String.length(reason) > 20, "#{inspect(resource)}.#{attribute} needs a reason"

        assert Ash.Resource.Info.attribute(resource, attribute),
               "#{inspect(resource)}.#{attribute} does not exist"

        assert DataInventory.looks_personal?(attribute)
      end
    end

    test "the heuristic is narrow" do
      for name <-
            ~w(email phone first_name last_name birth_date address national_id mobile_phone)a,
          do: assert(DataInventory.looks_personal?(name), inspect(name))

      for name <- ~w(name title status phoneme addressed)a,
          do: refute(DataInventory.looks_personal?(name), inspect(name))
    end
  end

  describe "tenancy" do
    test "tenant?: false resources are listed as global tables that cross the tenant boundary" do
      document = DataInventory.build()
      global = document["global_tables"]

      assert "AshEnterprise.Erasure.Scope" in global
      assert document["summary"]["global_tables"] == length(global)

      for entry <- document["resources"], entry["tenant_option"] == false do
        assert entry["tenancy"] == "global", entry["resource"]
        assert entry["resource"] in global == (entry["table"] != nil), entry["resource"]
      end

      # A resource with its own table and a tenant context is not listed.
      tenant_scoped =
        Enum.find(document["resources"], &(&1["tenancy"] != "global" and &1["table"]))

      refute tenant_scoped["resource"] in global

      # One with no table of its own (computed, in memory) is not a table at all.
      untabled = Enum.find(document["resources"], &(&1["table"] == nil))
      refute untabled["resource"] in global
    end
  end

  describe "entries" do
    test "every platform resource appears with ownership, tenancy, audit, archival, api exposure, sensitive and sealed attributes" do
      document = DataInventory.build()
      by_name = Map.new(document["resources"], &{&1["resource"], &1})

      for resource <- AshEnterprise.Platform.Seeder.platform_resources() do
        entry = Map.fetch!(by_name, inspect(resource))

        for key <-
              ~w(ownership tenancy audit archival api_type sensitive_attributes sealed_attributes table domain) do
          assert Map.has_key?(entry, key), "#{inspect(resource)} lacks #{key}"
        end
      end

      organization = by_name["AshEnterprise.Accounts.Organization"]
      assert organization["api_type"] == "organization"
      assert organization["ownership"] == "organization_owned"
      assert organization["audit"] == true
      assert organization["archival"] == true
      assert organization["table"]
    end

    test "sealed attributes carry the kind of sealing they live under" do
      by_name = Map.new(DataInventory.build()["resources"], &{&1["resource"], &1})

      task = by_name["AshEnterprise.Canonical.Task"]

      assert %{"attribute" => "encrypted_commitment", "sealing" => "erasure_scope"} in task[
               "sealed_attributes"
             ]
    end

    test "sensitive attributes are listed by name" do
      by_name = Map.new(DataInventory.build()["resources"], &{&1["resource"], &1})
      assert "hashed_password" in by_name["AshEnterprise.Accounts.User"]["sensitive_attributes"]
    end

    test "the platform section records api_type from the resource's option" do
      assert Spark.Dsl.Extension.get_opt(
               AshEnterprise.Accounts.Organization,
               [:platform],
               :api_type,
               nil
             ) ==
               :organization

      assert Spark.Dsl.Extension.get_opt(
               AshEnterprise.Erasure.Scope,
               [:platform],
               :api_type,
               :unset
             ) in [nil, :unset]
    end

    test "encoding is deterministic" do
      assert DataInventory.encode(DataInventory.build()) ==
               DataInventory.encode(DataInventory.build())
    end
  end

  defp check_against(content) do
    # Run the task's check against a different content, without touching the real file.
    path =
      Path.join(System.tmp_dir!(), "inventory-check-#{System.unique_integer([:positive])}.json")

    File.write!(path, content)

    try do
      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        if File.read!(path) == Task.render() do
          :ok
        else
          exit({:shutdown, 1})
        end
      end)
    after
      File.rm(path)
    end
  end
end
