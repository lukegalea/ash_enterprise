defmodule AshEnterprise.Platform.DefaultPaginationTest do
  @moduledoc """
  `AshEnterprise.Platform.Transformers.DefaultPagination`: every list read on a
  platform resource names a page size, gets and manual reads are left alone, and
  nothing that read without a page before gets a page now. SYNTHETIC data only.
  """

  use AshEnterprise.DataCase, async: false

  import AshEnterprise.Test.DailyFixtures

  alias Ash.Resource.Actions.Read
  alias AshEnterprise.Accounts.{BusinessUnit, Team}
  alias AshEnterprise.Platform.SystemActor
  alias AshEnterprise.Platform.Transformers.DefaultPagination
  alias AshEnterprise.Security.ActorContext

  defp platform_reads do
    for domain <- Application.fetch_env!(:ash_enterprise, :ash_domains),
        resource <- Ash.Domain.Info.resources(domain),
        AshEnterprise.Platform.SystemAttributes in Spark.extensions(resource),
        %Read{} = action <- Ash.Resource.Info.actions(resource),
        uniq: true,
        do: {resource, action}
  end

  defp list_read?(%Read{} = action), do: not action.get? and is_nil(action.manual)

  describe "what it leaves alone" do
    test "get? and manual reads are left alone" do
      assert DefaultPagination.paged(%Read{name: :one, get?: true}, true) == nil
      assert DefaultPagination.paged(%Read{name: :by_key, get_by: [:id]}, true) == nil

      assert DefaultPagination.paged(%Read{name: :computed, manual: {SomeManualRead, []}}, true) ==
               nil

      # And on the compiled resources: no get and no manual read was given a page.
      left_alone =
        for {resource, action} <- platform_reads(), not list_read?(action), do: {resource, action}

      assert Enum.any?(left_alone, fn {_, action} -> action.get? end)
      assert Enum.any?(left_alone, fn {_, action} -> action.manual end)

      for {resource, action} <- left_alone do
        assert action.pagination in [nil, false],
               "#{inspect(resource)}.#{action.name} is a get or manual read but was given #{inspect(action.pagination)}"
      end
    end

    test "a read that names its own default_limit keeps it" do
      declared = %Read.Pagination{default_limit: 30, max_page_size: 100, offset?: true}
      assert DefaultPagination.paged(%Read{name: :mine, pagination: declared}, true) == nil

      assert %Read{pagination: %{default_limit: 30}} =
               Ash.Resource.Info.action(AshEnterprise.Assistant.Thread, :mine)
    end

    test "an unpaged internal Ash.read! still returns a list (ActorContext unaffected)" do
      admin = tenant!()
      root = admin.user.owning_business_unit_id
      teams!(admin, 55)

      # 55 units under the root: a deep grant's subtree is read with an unpaged
      # Ash.read, and must come back whole, not as the first 50.
      for n <- 1..55 do
        BusinessUnit
        |> Ash.Changeset.for_create(:create, %{name: "Unit #{n}", parent_business_unit_id: root},
          authorize?: false,
          tenant: admin.tenant,
          actor: SystemActor.seed()
        )
        |> Ash.create!()
      end

      teams = Ash.read!(Team, tenant: admin.tenant, authorize?: false)
      assert is_list(teams)
      assert length(teams) > 55

      units = Ash.read!(BusinessUnit, tenant: admin.tenant, authorize?: false)
      assert is_list(units)
      assert length(units) == 56

      reader = member!(admin, "Deep team reader", [{Team, :read, :deep}])
      context = ActorContext.build(reader.user)

      assert %ActorContext.Grant{business_unit_ids: subtree} =
               ActorContext.grant(context, Team, :read)

      assert MapSet.size(subtree) == 56
    end
  end

  describe "what it sets" do
    test "every list read on a platform resource names a default_limit no larger than its max_page_size" do
      list_reads =
        for {resource, action} <- platform_reads(), list_read?(action), do: {resource, action}

      assert length(list_reads) > 100

      for {resource, action} <- list_reads do
        label = "#{inspect(resource)}.#{action.name}"
        assert %Read.Pagination{} = action.pagination, "#{label} does not page"
        assert is_integer(action.pagination.default_limit), "#{label} names no default_limit"
        assert is_integer(action.pagination.max_page_size), "#{label} names no max_page_size"
        assert action.pagination.default_limit <= action.pagination.max_page_size, label
      end
    end

    test "a hand-written read gets Ash's default pagination with a page size, and stays optional" do
      assert %Read{
               pagination: %Read.Pagination{
                 keyset?: true,
                 offset?: true,
                 required?: false,
                 paginate_by_default?: false,
                 countable: true,
                 default_limit: 50,
                 max_page_size: 250
               }
             } = Ash.Resource.Info.action(Team, :archived)

      assert %Read{pagination: %{default_limit: 50, max_page_size: 250, required?: false}} =
               Ash.Resource.Info.action(Team, :read)
    end

    test "a page that names no limit gets 50 rows, and a larger limit is clamped to 250" do
      admin = tenant!()
      teams!(admin, 60)

      page = Ash.read!(Team, tenant: admin.tenant, authorize?: false, page: [offset: 0])
      assert %Ash.Page.Offset{limit: 50, results: results, more?: true} = page
      assert length(results) == 50

      assert %{limit: 250} =
               Ash.read!(Team, tenant: admin.tenant, authorize?: false, page: [limit: 10_000])
    end
  end
end
