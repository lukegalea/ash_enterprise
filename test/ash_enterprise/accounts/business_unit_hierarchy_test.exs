defmodule AshEnterprise.Accounts.BusinessUnitHierarchyTest do
  @moduledoc """
  The derived hierarchy display: `ancestors`, `breadcrumb` and `tree_label`.

  These exist because the materialized `path` is a chain of UUIDs. It stays that
  way — it is an authorization structure, read as a prefix comparison by every
  Deep grant — so these are its *display*, derived, and never a second source of
  truth.

  Two properties are load-bearing and neither is obvious from reading the code:

    * `ancestors` joins on a path prefix rather than by walking
      `parent_business_unit_id`, so a breadcrumb is one lateral join instead of
      one query per level. It includes self, because a unit's own path is a
      prefix of itself.

    * `tree_label`'s indentation is only correct when rows are sorted by `path`
      ascending. That works because every path segment is a fixed-width UUID, so
      lexicographic order *is* depth-first pre-order — a parent is always
      immediately followed by its own subtree. Sorting by anything else produces
      indentation that describes a different tree than the one displayed, which
      is worse than no indentation at all.
  """

  use AshEnterprise.DataCase, async: false

  alias AshEnterprise.Accounts.BusinessUnit

  require Ash.Query

  setup do
    org = Ash.UUID.generate()

    root = unit("Root", nil, org)
    eng = unit("Engineering", root, org)
    sales = unit("Sales", root, org)
    platform = unit("Platform", eng, org)

    %{org: org, root: root, eng: eng, sales: sales, platform: platform}
  end

  test "ancestors runs root-first and includes the unit itself", ctx do
    names =
      ctx.platform
      |> Ash.load!([:ancestor_names], authorize?: false, tenant: ctx.org)
      |> Map.fetch!(:ancestor_names)

    assert names == ["Root", "Engineering", "Platform"]
  end

  test "breadcrumb renders the ancestor names, not the uuids", ctx do
    platform = Ash.load!(ctx.platform, [:breadcrumb], authorize?: false, tenant: ctx.org)

    assert platform.breadcrumb == "Root / Engineering / Platform"
    refute platform.breadcrumb =~ ctx.root.id
  end

  test "the root's breadcrumb is its own name", ctx do
    root = Ash.load!(ctx.root, [:breadcrumb], authorize?: false, tenant: ctx.org)

    assert root.breadcrumb == "Root"
  end

  test "sorting by path yields depth-first pre-order, so indentation lines up", ctx do
    labels =
      BusinessUnit
      |> Ash.Query.sort(path: :asc)
      |> Ash.Query.load([:tree_label])
      |> Ash.read!(authorize?: false, tenant: ctx.org)
      |> Enum.map(& &1.tree_label)

    # Root first, then each child immediately followed by its own subtree.
    # Engineering's child appears before Sales even though "Sales" sorts first
    # alphabetically -- that is the point of ordering by path.
    assert [root_label | rest] = labels
    assert root_label == "Root"

    indents = Enum.map(rest, &indent_of/1)
    assert Enum.all?(rest, &String.contains?(&1, "└─ "))

    # Every unit sits deeper than nothing, and Platform (depth 2) sits deeper
    # than the depth-1 units around it.
    assert Enum.all?(indents, &(&1 > 0))

    assert indent_of(Enum.find(rest, &String.ends_with?(&1, "Platform"))) >
             indent_of(Enum.find(rest, &String.ends_with?(&1, "Engineering")))
  end

  test "the indent is non-breaking spaces, which markdown will not collapse", ctx do
    eng = Ash.load!(ctx.eng, [:tree_label], authorize?: false, tenant: ctx.org)

    # Literal spaces would collapse, and four of them at the start of a line
    # would make markdown render the row as a code block instead of a heading.
    assert eng.tree_label =~ "&nbsp;"
    refute String.starts_with?(eng.tree_label, " ")
  end

  defp indent_of(label) do
    label |> String.split("└─") |> hd() |> String.split("&nbsp;") |> length()
  end

  defp unit(name, parent, org) do
    BusinessUnit
    |> Ash.Changeset.for_create(
      :create,
      %{name: name, parent_business_unit_id: parent && parent.id},
      authorize?: false,
      tenant: org
    )
    |> Ash.create!()
  end
end
