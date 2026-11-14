defmodule AshEnterprise.Platform.BoundedReadsTest do
  @moduledoc """
  No list surface returns a whole table: every JSON:API index and GraphQL list
  names a read whose paging is required, and every AshAi read tool names a read
  whose page size is capped (`AshEnterprise.Test.BoundedReads`).

  A test rather than a compile-time verifier, so a surface added on a branch
  fails here, in CI, instead of failing every other branch's compile.
  """

  use ExUnit.Case, async: true

  alias Ash.Resource.Actions.Read
  alias AshEnterprise.Test.BoundedReads

  # AshAi read tools over manual reads. AshAi hands its limit to the manual code,
  # which may ignore it, so each is listed with the bound it applies itself. A new
  # manual read tool fails the last test until it is listed here. "reads" bounds the
  # query; "shows" reads within the named window and keeps the first N.
  @self_bounded_manual_tools %{
    {AshEnterprise.Assistant.Lookup.Account, "tool my_accounts"} => "reads 20",
    {AshEnterprise.Assistant.Lookup.ActivityCount, "tool count_activity"} => "shows 25",
    {AshEnterprise.Assistant.Lookup.Approval, "tool pending_approvals"} => "reads 25",
    {AshEnterprise.Assistant.Lookup.Brief, "tool morning_briefs"} => "reads 3 to 14",
    {AshEnterprise.Assistant.Lookup.CalendarEvent, "tool calendar_events"} => "shows 25",
    {AshEnterprise.Assistant.Lookup.Conversation, "tool find_conversations"} => "shows 25",
    {AshEnterprise.Assistant.Lookup.Duplicate, "tool steward_queue"} => "reads 25",
    {AshEnterprise.Assistant.Lookup.Message, "tool read_messages"} => "shows 20",
    {AshEnterprise.Assistant.Lookup.Person, "tool find_people"} => "reads 15",
    {AshEnterprise.Assistant.Lookup.StalledReview, "tool stalled_reviews"} => "reads 25",
    {AshEnterprise.Assistant.Lookup.Task, "tool my_tasks"} => "reads 30",
    {AshEnterprise.Assistant.Lookup.WorkEntry, "tool trace"} => "shows 60",
    {AshEnterprise.Assistant.Lookup.WorkEntry, "tool explain"} => "shows 60",
    {AshEnterprise.Assistant.Compose, "tool compose_surface"} => "composes one surface"
  }

  defp pages_only_when_asked do
    %Read{
      name: :fixture,
      pagination: %Read.Pagination{
        keyset?: true,
        offset?: true,
        required?: false,
        paginate_by_default?: false,
        default_limit: 50,
        max_page_size: 250
      }
    }
  end

  describe "the checker" do
    test "an index route or list query over an action that does not page by default is reported" do
      for kind <- [:json_api_index, :graphql_list] do
        assert BoundedReads.problem(kind, pages_only_when_asked()) =~ "pages only when asked"

        assert BoundedReads.problem(kind, %Read{name: :fixture, pagination: false}) ==
                 "does not page"

        assert BoundedReads.problem(kind, %Read{name: :fixture, pagination: nil}) ==
                 "does not page"
      end
    end

    test "a page with no size, an uncapped size or a default above the cap is reported" do
      required = %{pages_only_when_asked().pagination | required?: true}

      for kind <- [:json_api_index, :graphql_list, :ash_ai_tool] do
        no_default = %Read{name: :fixture, pagination: %{required | default_limit: nil}}
        assert BoundedReads.problem(kind, no_default) == "names no default_limit"

        uncapped = %Read{name: :fixture, pagination: %{required | max_page_size: nil}}
        assert BoundedReads.problem(kind, uncapped) =~ "names no max_page_size"

        inverted = %Read{name: :fixture, pagination: %{required | default_limit: 500}}
        assert BoundedReads.problem(kind, inverted) =~ "above max_page_size"
      end
    end

    test "an AshAi tool over a read that does not page, or a manual read, is reported" do
      assert BoundedReads.problem(:ash_ai_tool, %Read{name: :fixture, pagination: false}) ==
               "does not page"

      assert BoundedReads.problem(:ash_ai_tool, %Read{name: :fixture, manual: {SomeRead, []}}) =~
               "a manual read"
    end

    test "a required page with a capped default is bounded" do
      required = %Read{
        name: :fixture,
        pagination: %{pages_only_when_asked().pagination | required?: true}
      }

      by_default = %Read{
        name: :fixture,
        pagination: %{pages_only_when_asked().pagination | paginate_by_default?: true}
      }

      for kind <- [:json_api_index, :graphql_list, :ash_ai_tool],
          read <- [required, by_default] do
        assert BoundedReads.problem(kind, read) == nil
      end

      # AshAi always passes a limit, so a page size is enough there.
      assert BoundedReads.problem(:ash_ai_tool, pages_only_when_asked()) == nil
    end
  end

  describe "the application" do
    test "every JSON:API index, GraphQL list and AshAi read tool pages by default" do
      surfaces = BoundedReads.surfaces()

      # Not vacuous: the three Accounts lists on both APIs, and the read tools.
      for kind <- [:json_api_index, :graphql_list] do
        assert surfaces |> Enum.filter(&(&1.kind == kind)) |> length() >= 3
      end

      assert Enum.any?(surfaces, &(&1.kind == :ash_ai_tool and &1.action.manual == nil))

      problems =
        for surface <- surfaces,
            problem = BoundedReads.problem(surface.kind, surface.action),
            not Map.has_key?(@self_bounded_manual_tools, {surface.resource, surface.name}),
            do: "#{surface.kind} #{inspect(surface.resource)} #{surface.name}: #{problem}"

      assert problems == [], Enum.join(problems, "\n")
    end

    test "the manual read tools listed as bounding themselves are exactly the manual ones" do
      manual =
        for surface <- BoundedReads.surfaces(),
            surface.kind == :ash_ai_tool,
            surface.action.manual,
            into: MapSet.new(),
            do: {surface.resource, surface.name}

      assert manual == MapSet.new(Map.keys(@self_bounded_manual_tools))
    end
  end
end
