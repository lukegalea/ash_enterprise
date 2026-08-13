defmodule AshEnterprise.Accounts.BusinessUnitTest do
  @moduledoc """
  Tests for the materialized-path hierarchy.

  This is the least obvious code in the identity domain and the most
  consequential: `path` is what makes the `Deep` access level a prefix match
  instead of a recursive query, so a bug here does not produce an error — it
  produces *wrong authorization*, silently, at scale.

  The reparenting cases matter most. A detached subtree keeps working for `Basic`
  and `Global` checks while becoming invisible to every `Deep` check, which is
  exactly the kind of failure nobody notices until an audit.
  """

  use AshEnterprise.DataCase, async: false

  alias AshEnterprise.Accounts.BusinessUnit

  # Authorization is not the subject here, and the policy engine lands in
  # Phase 6. These tests exercise the path arithmetic directly.
  @opts [authorize?: false]

  defp org_id, do: Ash.UUID.generate()

  defp create_bu(name, parent \\ nil, organization_id) do
    BusinessUnit
    |> Ash.Changeset.for_create(
      :create,
      %{name: name, parent_business_unit_id: parent && parent.id},
      Keyword.put(@opts, :tenant, organization_id)
    )
    |> Ash.create!()
  end

  defp reload(bu, organization_id) do
    BusinessUnit
    |> Ash.get!(bu.id, Keyword.put(@opts, :tenant, organization_id))
  end

  describe "path derivation" do
    test "a root business unit gets a path of just its own id, at depth 0" do
      org = org_id()
      root = create_bu("Root", nil, org)

      assert root.path == "/#{root.id}/"
      assert root.depth == 0
    end

    test "a child's path extends its parent's, and depth increments" do
      org = org_id()
      root = create_bu("Root", nil, org)
      emea = create_bu("EMEA", root, org)
      uk = create_bu("UK", emea, org)

      assert emea.path == "/#{root.id}/#{emea.id}/"
      assert emea.depth == 1

      assert uk.path == "/#{root.id}/#{emea.id}/#{uk.id}/"
      assert uk.depth == 2
    end

    test "a descendant's path contains every ancestor id, so a prefix match finds the subtree" do
      org = org_id()
      root = create_bu("Root", nil, org)
      emea = create_bu("EMEA", root, org)
      uk = create_bu("UK", emea, org)

      # This is precisely the query the Deep depth check relies on.
      assert String.starts_with?(uk.path, root.path)
      assert String.starts_with?(uk.path, emea.path)
    end
  end

  describe "subtree read action" do
    test "returns the node itself and all descendants, but not siblings" do
      org = org_id()
      root = create_bu("Root", nil, org)
      emea = create_bu("EMEA", root, org)
      uk = create_bu("UK", emea, org)
      apac = create_bu("APAC", root, org)

      subtree_ids =
        BusinessUnit
        |> Ash.Query.for_read(
          :subtree,
          %{business_unit_id: emea.id},
          Keyword.put(@opts, :tenant, org)
        )
        |> Ash.read!()
        |> Enum.map(& &1.id)
        |> Enum.sort()

      assert subtree_ids == Enum.sort([emea.id, uk.id])
      refute apac.id in subtree_ids
      refute root.id in subtree_ids
    end

    test "an unknown business unit yields an empty subtree rather than an error" do
      org = org_id()
      _root = create_bu("Root", nil, org)

      assert {:ok, []} =
               BusinessUnit
               |> Ash.Query.for_read(
                 :subtree,
                 %{business_unit_id: Ash.UUID.generate()},
                 Keyword.put(@opts, :tenant, org)
               )
               |> Ash.read()
    end
  end

  describe "reparenting" do
    test "moving a node rewrites the paths of its entire subtree" do
      org = org_id()
      root = create_bu("Root", nil, org)
      emea = create_bu("EMEA", root, org)
      uk = create_bu("UK", emea, org)
      london = create_bu("London", uk, org)
      apac = create_bu("APAC", root, org)

      # Move UK (and London beneath it) from EMEA to APAC.
      uk
      |> Ash.Changeset.for_update(
        :update,
        %{parent_business_unit_id: apac.id},
        Keyword.put(@opts, :tenant, org)
      )
      |> Ash.update!()

      uk = reload(uk, org)
      london = reload(london, org)

      assert uk.path == "/#{root.id}/#{apac.id}/#{uk.id}/"
      assert uk.depth == 2

      # The grandchild must have moved with it. If this fails, London is
      # unreachable from any Deep check rooted at APAC.
      assert london.path == "/#{root.id}/#{apac.id}/#{uk.id}/#{london.id}/"
      assert london.depth == 3
    end

    test "a moved subtree is found under its new parent and not its old one" do
      org = org_id()
      root = create_bu("Root", nil, org)
      emea = create_bu("EMEA", root, org)
      uk = create_bu("UK", emea, org)
      apac = create_bu("APAC", root, org)

      uk
      |> Ash.Changeset.for_update(
        :update,
        %{parent_business_unit_id: apac.id},
        Keyword.put(@opts, :tenant, org)
      )
      |> Ash.update!()

      apac_subtree = subtree_ids(apac, org)
      emea_subtree = subtree_ids(emea, org)

      assert uk.id in apac_subtree
      refute uk.id in emea_subtree
    end
  end

  describe "cycle prevention" do
    test "a business unit cannot be its own parent" do
      org = org_id()
      root = create_bu("Root", nil, org)

      assert {:error, error} =
               root
               |> Ash.Changeset.for_update(
                 :update,
                 %{parent_business_unit_id: root.id},
                 Keyword.put(@opts, :tenant, org)
               )
               |> Ash.update()

      assert Exception.message(error) =~ "cannot be its own parent"
    end

    test "a business unit cannot be moved beneath its own descendant" do
      org = org_id()
      root = create_bu("Root", nil, org)
      emea = create_bu("EMEA", root, org)
      uk = create_bu("UK", emea, org)

      # Moving EMEA under UK would detach the whole subtree from the root, making
      # it invisible to every Deep check while still existing.
      assert {:error, error} =
               emea
               |> Ash.Changeset.for_update(
                 :update,
                 %{parent_business_unit_id: uk.id},
                 Keyword.put(@opts, :tenant, org)
               )
               |> Ash.update()

      assert Exception.message(error) =~ "descendant"
    end
  end

  describe "tenant isolation" do
    test "a subtree never crosses tenants" do
      org_a = org_id()
      org_b = org_id()

      root_a = create_bu("Root", nil, org_a)
      _child_a = create_bu("Child", root_a, org_a)
      root_b = create_bu("Root", nil, org_b)
      _child_b = create_bu("Child", root_b, org_b)

      assert length(subtree_ids(root_a, org_a)) == 2
      assert length(subtree_ids(root_b, org_b)) == 2

      assert subtree_ids(root_a, org_a) -- subtree_ids(root_b, org_b) ==
               subtree_ids(root_a, org_a)
    end
  end

  defp subtree_ids(bu, organization_id) do
    BusinessUnit
    |> Ash.Query.for_read(
      :subtree,
      %{business_unit_id: bu.id},
      Keyword.put(@opts, :tenant, organization_id)
    )
    |> Ash.read!()
    |> Enum.map(& &1.id)
  end
end
