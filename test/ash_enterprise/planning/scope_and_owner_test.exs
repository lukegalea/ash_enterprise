defmodule AshEnterprise.Planning.ScopeAndOwnerTest do
  @moduledoc """
  `ScopeAndOwner, from: :run` reads the owner and erasure scope from the resource named by
  `resource:`, defaulting to `Planning.Run`; a bad option is refused at compile time.
  """

  use AshEnterprise.DataCase, async: false

  import AshEnterprise.Planning.TestKit

  alias AshEnterprise.Planning
  alias AshEnterprise.Planning.{Candidate, Run}
  alias AshEnterprise.Planning.Changes.ScopeAndOwner

  setup do
    publish_requirements!()
    w = world!()

    candidate =
      Planning.propose_planning_candidate!(
        %{run_id: w.run.id, index: 1, assignments: Jason.encode!([])},
        w.oban
      )

    %{w: w, candidate: candidate}
  end

  defp change(run_id, tenant, opts) do
    Candidate
    |> Ash.Changeset.new()
    |> Ash.Changeset.set_tenant(tenant)
    |> Ash.Changeset.force_change_attribute(:run_id, run_id)
    |> ScopeAndOwner.change(opts, %Ash.Resource.Change.Context{actor: nil})
  end

  test "without resource: the run is a Planning.Run", %{w: w} do
    cs = change(w.run.id, w.admin.tenant, from: :run)

    assert cs.valid?
    assert Ash.Changeset.get_attribute(cs, :owner_id) == w.run.owner_id
    assert Ash.Changeset.get_attribute(cs, :erasure_scope_id) == w.run.erasure_scope_id
  end

  test "resource: reads the owner and scope from that resource", %{w: w, candidate: candidate} do
    cs = change(candidate.id, w.admin.tenant, from: :run, resource: Candidate)

    assert cs.valid?
    assert Ash.Changeset.get_attribute(cs, :owner_id) == candidate.owner_id
    assert Ash.Changeset.get_attribute(cs, :erasure_scope_id) == candidate.erasure_scope_id
  end

  test "an id of another resource is not found in the named one", %{w: w} do
    cs = change(w.run.id, w.admin.tenant, from: :run, resource: Candidate)

    refute cs.valid?
    assert Enum.any?(cs.errors, &(&1.field == :run_id))
    assert is_nil(Ash.Changeset.get_attribute(cs, :erasure_scope_id))
  end

  test "init refuses a resource that is not a module, or on another source" do
    assert {:ok, _} = ScopeAndOwner.init(from: :run, resource: Run)
    assert {:error, "resource must be a module"} = ScopeAndOwner.init(from: :run, resource: "x")

    assert {:error, "resource is only for from: :run"} =
             ScopeAndOwner.init(from: :candidate, resource: Run)

    assert {:error, "resource is only for from: :run"} =
             ScopeAndOwner.init(from: :requester, resource: Run)
  end
end
