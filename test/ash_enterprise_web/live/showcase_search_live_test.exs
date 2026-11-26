defmodule AshEnterpriseWeb.ShowcaseSearchLiveTest do
  @moduledoc """
  The showcase's three-valued search beat (`/app/showcase/search`), end to end over the
  seeded synthetic clinicians: a filter with a judged predicate gives three groups, in, out
  and unknown, with each unknown's reason; changing the filter moves rows between the
  groups; the CQL2 the person sees and edits is what runs; and every run is recorded.

  SYNTHETIC data only.
  """

  use AshEnterpriseWeb.ConnCase, async: false

  # The clinic's demo data ingests its licence documents into the evidence store.
  @moduletag evidence: true

  import Phoenix.LiveViewTest

  alias AshEnterprise.Platform.DemoTenant
  alias AshEnterprise.Showcase.Search
  alias AshEnterprise.SystemOne.{Fact, FilterExecution, FilterProposal}

  @path "/app/showcase/search"

  defp sign_in(user) do
    {:ok, token, _claims} = AshAuthentication.Jwt.token_for_user(user)

    build_conn()
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session("user_token", token)
  end

  defp id(n), do: "showcase-search-#{n}"

  # The ids of the clinicians in one group, in the order shown.
  defp members(view, group) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("##{group} li")
    |> Enum.flat_map(&LazyHTML.attribute(&1, "data-subject"))
    |> Enum.sort()
  end

  defp pick_and_run(view, preset) do
    view |> element("#pick-#{preset}") |> render_click()
    view |> form("#search-form") |> render_submit()
  end

  setup do
    %{organization: organization, clinic: clinic} = DemoTenant.run!()
    {:ok, view, _html} = live(sign_in(clinic.coordinator), @path)
    %{organization: organization, clinic: clinic, view: view}
  end

  test "nothing runs, and no result shows, until the person approves a filter", %{view: view} do
    assert has_element?(view, "#search-filter")
    assert has_element?(view, "#search-no-model")
    refute has_element?(view, "#search-result")

    view |> element("#pick-legible") |> render_click()
    assert render(view) =~ "licence_scan_legible"
    refute has_element?(view, "#search-result")
    assert FilterExecution |> Ash.read!(authorize?: false) |> Enum.empty?()
  end

  test "a judged filter gives three groups, and the unknown group says why", %{view: view} do
    pick_and_run(view, "legible")

    assert members(view, "group-in") == [id(1), id(2), id(3)]
    assert members(view, "group-out") == [id(4), id(5), id(6)]
    assert members(view, "group-unknown") == [id(7), id(8), id(9)]

    assert has_element?(view, "#group-unknown-#{id(7)} [data-reason=no_fact]")
    assert has_element?(view, "#group-unknown-#{id(8)} [data-reason=no_fact]")
    assert has_element?(view, "#group-unknown-#{id(9)} [data-reason=expired]")
  end

  test "toggling the filter moves rows between the groups, and unknown stays unknown",
       %{view: view} do
    pick_and_run(view, "legible")
    assert id(1) in members(view, "group-in")
    assert id(4) in members(view, "group-out")

    pick_and_run(view, "illegible")
    assert members(view, "group-in") == [id(4), id(5), id(6)]
    assert members(view, "group-out") == [id(1), id(2), id(3)]
    assert members(view, "group-unknown") == [id(7), id(8), id(9)]
  end

  test "a conjunction keeps unknown unless a clause is false", %{view: view} do
    pick_and_run(view, "toronto_legible")

    assert members(view, "group-in") == [id(1), id(3)]
    # Toronto and not legible, and everyone outside Toronto, however little is known of them.
    assert members(view, "group-out") == [id(2), id(4), id(5), id(6), id(8)]
    assert members(view, "group-unknown") == [id(7), id(9)]
  end

  test "asking for the unassessed is the unknown group, spelled as a filter", %{view: view} do
    pick_and_run(view, "not_assessed")

    assert members(view, "group-in") == [id(7), id(8), id(9)]
    assert members(view, "group-unknown") == []
  end

  test "the text the person edited is what runs", %{view: view} do
    view |> element("#pick-legible") |> render_click()

    edited =
      Jason.encode!(%{
        "op" => "=",
        "args" => [%{"property" => "city"}, "Ottawa"]
      })

    view |> form("#search-form", search: %{text: edited}) |> render_submit()

    assert members(view, "group-in") == [id(2), id(5), id(8)]
    assert members(view, "group-unknown") == []
  end

  test "text that is not a filter runs nothing", %{view: view} do
    view |> form("#search-form", search: %{text: "not json"}) |> render_submit()
    assert has_element?(view, "#search-error")
    refute has_element?(view, "#search-result")

    ghost = Jason.encode!(%{"op" => "=", "args" => [%{"property" => "no_such"}, true]})
    view |> form("#search-form", search: %{text: ghost}) |> render_submit()
    assert has_element?(view, "#search-error")
    refute has_element?(view, "#search-result")

    assert FilterExecution |> Ash.read!(authorize?: false) |> Enum.empty?()
  end

  test "words propose a filter in the box, and an edit of it is a new version",
       %{view: view, organization: organization} do
    view
    |> form("#words-form", words: %{words: "Clinicians whose licence scan is legible"})
    |> render_submit()

    assert render(view) =~ "licence_scan_legible"
    refute has_element?(view, "#search-error")

    edited =
      Jason.encode!(%{
        "op" => "=",
        "args" => [%{"property" => Search.question_id()}, false]
      })

    view |> form("#search-form", search: %{text: edited}) |> render_submit()
    assert members(view, "group-in") == [id(4), id(5), id(6)]

    proposals =
      FilterProposal
      |> Ash.read!(tenant: organization.id, authorize?: false)
      |> Enum.sort_by(& &1.version)

    assert Enum.map(proposals, &{&1.version, &1.status}) == [{1, :superseded}, {2, :approved}]
    assert Enum.all?(proposals, &(&1.source == "showcase"))
  end

  test "a person who may not read the facts finds nothing, not everything unknown",
       %{clinic: clinic} do
    [member | _rest] = clinic.committee
    {:ok, view, _html} = live(sign_in(member), @path)

    pick_and_run(view, "legible")

    assert has_element?(view, "#search-empty")
    refute has_element?(view, "#group-unknown")
  end

  test "words nobody recorded propose nothing", %{view: view} do
    view |> form("#words-form", words: %{words: "everyone in Calgary"}) |> render_submit()
    assert has_element?(view, "#search-error")
    refute has_element?(view, "#search-result")
  end

  test "every run is recorded with the search's own counts", %{
    view: view,
    organization: organization
  } do
    pick_and_run(view, "legible")

    assert [execution] = Ash.read!(FilterExecution, tenant: organization.id, authorize?: false)
    assert {execution.in_count, execution.out_count, execution.unknown_count} == {3, 3, 3}
    assert execution.plan["subject_type"] == Search.subject_type()
  end

  test "seeding is idempotent, and the search sees only its own clinicians",
       %{organization: organization, clinic: clinic} do
    facts = fn -> Fact |> Ash.read!(authorize?: false) |> length() end
    before = facts.()

    assert %{facts: 16} = Search.seed!(organization, clinic.coordinator)
    assert facts.() == before

    {:ok, view, _html} = live(sign_in(clinic.coordinator), @path)
    pick_and_run(view, "legible")

    all = ~w(group-in group-out group-unknown) |> Enum.flat_map(&members(view, &1))
    assert length(all) == 9
  end
end
