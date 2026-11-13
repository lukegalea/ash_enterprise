defmodule AshEnterpriseWeb.Decisions.TryLiveTest do
  @moduledoc """
  The decisions try-it panel (`/app/decisions/:key/try`): run a draft or a published version
  against sample inputs. The refusals come first because the panel evaluates tenant-authored
  rules: another tenant, and a person with no read on decisions, get nothing to try; invalid
  input is an error, not an evaluation; and a trial never writes an `Evaluation`.
  """

  use AshEnterpriseWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias AshEnterprise.Decisions.{Definition, Evaluation}
  alias AshEnterprise.Platform.SystemActor
  alias AshEnterprise.Test.AssistantFixtures

  @key "access_request.risk"
  @xml File.read!("priv/dmn/access_request_risk.dmn")
  # The draft changes one answer so a trial can tell the two versions apart.
  @draft_xml String.replace(
               @xml,
               ~s|<outputEntry id="o_priv"><text>"high"</text>|,
               ~s|<outputEntry id="o_priv"><text>"medium"</text>|
             )

  setup do
    admin = AssistantFixtures.tenant!()
    system = [actor: SystemActor.process(), tenant: admin.tenant]

    published =
      @key
      |> definition!(@xml, system)
      |> Definition.publish!(system)

    draft = definition!(@key, @draft_xml, system)

    %{admin: admin, published: published, draft: draft}
  end

  defp definition!(key, xml, opts), do: Definition.create!(%{key: key, name: key, xml: xml}, opts)

  defp sign_in(user) do
    {:ok, token, _claims} = AshAuthentication.Jwt.token_for_user(user)

    build_conn()
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session("user_token", token)
  end

  defp evaluations(tenant) do
    Evaluation
    |> Ash.Query.for_read(:read)
    |> Ash.read!(actor: SystemActor.process(), tenant: tenant)
  end

  defp path, do: "/app/decisions/#{@key}/try"

  defp try_it(view, version, tier, length) do
    view
    |> form("#decision-try-form", %{
      "version" => version.id,
      "inputs" => %{"requestedRoleTier" => tier, "justificationLength" => length}
    })
    |> render_submit()
  end

  describe "refusals" do
    test "another tenant has nothing to try, and cannot try by id", %{draft: draft} do
      other = AssistantFixtures.tenant!()
      {:ok, view, _html} = live(sign_in(other.user), path())

      assert has_element?(view, "#decision-try-refused")
      refute has_element?(view, "#decision-try-form")

      render_hook(view, "try", %{
        "version" => draft.id,
        "inputs" => %{"requestedRoleTier" => "privileged", "justificationLength" => "1"}
      })

      assert has_element?(view, "#decision-try-refused")
      refute has_element?(view, "#decision-try-result")
      assert evaluations(other.tenant) == []
    end

    test "someone in the tenant who may not read decisions has nothing to try", %{admin: admin} do
      nobody = AssistantFixtures.colleague!(admin)
      {:ok, view, _html} = live(sign_in(nobody.user), path())

      assert has_element?(view, "#decision-try-refused")
      refute has_element?(view, "#decision-try-form")
    end

    test "an unknown key has nothing to try", %{admin: admin} do
      {:ok, view, _html} = live(sign_in(admin.user), "/app/decisions/no.such.key/try")

      assert has_element?(view, "#decision-try-refused")
    end
  end

  describe "input errors" do
    test "invalid input shows an error and evaluates nothing", %{admin: admin, draft: draft} do
      {:ok, view, _html} = live(sign_in(admin.user), path())

      try_it(view, draft, "privileged", "lots")

      assert has_element?(view, "#decision-try-error-justificationLength")
      refute has_element?(view, "#decision-try-result")
      assert evaluations(admin.tenant) == []
    end

    test "a blank input is refused rather than read as zero", %{admin: admin, draft: draft} do
      {:ok, view, _html} = live(sign_in(admin.user), path())

      try_it(view, draft, "", "10")

      assert has_element?(view, "#decision-try-error-requestedRoleTier")
      refute has_element?(view, "#decision-try-result")
    end
  end

  describe "trying a version" do
    test "a draft opens first and shows its answer and the rule that fired", %{
      admin: admin,
      draft: draft
    } do
      {:ok, view, _html} = live(sign_in(admin.user), path())

      assert has_element?(view, "#decision-try-version option[selected][value='#{draft.id}']")
      assert has_element?(view, "#decision-try-input-requestedRoleTier")
      assert has_element?(view, "#decision-try-input-justificationLength")

      try_it(view, draft, "privileged", "10")

      assert has_element?(view, "#decision-try-outputs", "medium")
      assert has_element?(view, "#decision-try-rule-rule_privileged")
      refute has_element?(view, "#decision-try-error")
    end

    test "a published version answers as it was published", %{
      admin: admin,
      published: published
    } do
      {:ok, view, _html} = live(sign_in(admin.user), path())

      view |> form("#decision-try-version-form", %{"version" => published.id}) |> render_change()
      try_it(view, published, "privileged", "10")

      assert has_element?(view, "#decision-try-outputs", "high")
      assert has_element?(view, "#decision-try-rule-rule_privileged")
    end

    test "a case no rule covers is reported as no match", %{admin: admin, published: published} do
      {:ok, view, _html} = live(sign_in(admin.user), path())

      view |> form("#decision-try-version-form", %{"version" => published.id}) |> render_change()
      try_it(view, published, "unheard-of", "10")

      assert has_element?(view, "#decision-try-no-rules")
    end

    test "trying writes no Evaluation", %{admin: admin, draft: draft, published: published} do
      {:ok, view, _html} = live(sign_in(admin.user), path())
      before_count = length(evaluations(admin.tenant))

      try_it(view, draft, "privileged", "10")
      view |> form("#decision-try-version-form", %{"version" => published.id}) |> render_change()
      try_it(view, published, "elevated", "5")
      try_it(view, published, "elevated", "oops")

      assert length(evaluations(admin.tenant)) == before_count
      assert before_count == 0
    end
  end

  describe "this application's wiring of the package page" do
    test "it sits in the application layout, with the link back to the catalogue", %{
      admin: admin
    } do
      {:ok, view, _html} = live(sign_in(admin.user), path())

      assert has_element?(view, "#decision-try")
      assert has_element?(view, "#decision-try-back[href='/app/decisions']")
    end

    test "the page and its errors are in the reader's language", %{admin: admin, draft: draft} do
      {:ok, view, _html} =
        admin.user
        |> sign_in()
        |> put_req_header("accept-language", "fr")
        |> live(path())

      assert has_element?(view, "#decision-try h1", "Essayer #{@key}")
      assert has_element?(view, "#decision-try-submit", "Essayer")
      assert has_element?(view, "#decision-try-back", "Toutes les décisions")

      try_it(view, draft, "privileged", "lots")

      assert has_element?(
               view,
               "#decision-try-error-justificationLength",
               "Saisissez un nombre, par exemple 42 ou 3,5."
             )
    end
  end

  test "the catalogue links a tenant's own decision to its panel", %{admin: admin} do
    {:ok, view, _html} = live(sign_in(admin.user), "/app/decisions")

    assert has_element?(view, "[id='try-decision-#{@key}']")
  end
end
