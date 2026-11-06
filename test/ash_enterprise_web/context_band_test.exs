defmodule AshEnterpriseWeb.ContextBandTest do
  @moduledoc """
  The context band in the app layout (`AshEnterpriseWeb.Layouts.context_band/1`) and what
  it is built from (`AshEnterpriseWeb.SessionContext`): the tenant, whom the person acts
  as, and the operator behind them when they act on someone else's behalf. A tenant or
  operator that cannot be read is said to be unknown, never left blank.
  """

  use AshEnterpriseWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import AshEnterprise.Test.DailyFixtures, only: [tenant!: 0, tenant!: 1, member!: 3]

  alias AshEnterprise.Security.{ActorContext, Impersonation}
  alias AshEnterpriseWeb.{Layouts, SessionContext}

  defp sign_in(conn, user) do
    {:ok, token, _claims} = AshAuthentication.Jwt.token_for_user(user)

    conn
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session("user_token", token)
  end

  defp band(context), do: render_component(&Layouts.context_band/1, context: context)

  defp text(html, selector),
    do: html |> LazyHTML.from_fragment() |> LazyHTML.query(selector) |> LazyHTML.text()

  describe "on a page" do
    test "every surface shows the tenant and who is signed in", %{conn: conn} do
      ctx = tenant!()

      for path <- ~w(/app /app/today /app/calendar) do
        {:ok, view, _html} = live(sign_in(conn, ctx.user), path)

        assert has_element?(view, "#context-tenant[data-tenant=named]", ctx.organization.name),
               path

        assert has_element?(view, "#context-identity", "Signed in as"), path
        assert has_element?(view, "#context-identity", ctx.email), path
        refute has_element?(view, "#context-impersonation"), path
      end
    end

    test "a member with no grant on the organization still sees its name", %{conn: conn} do
      admin = tenant!()
      member = member!(admin, "Calendar reader", [])

      {:ok, view, _html} = live(sign_in(conn, member.user), "/app")

      assert has_element?(view, "#context-tenant[data-tenant=named]", admin.organization.name)
      assert has_element?(view, "#context-identity", to_string(member.user.email))
    end
  end

  describe "SessionContext.for_actor/1" do
    test "names the tenant and the identity of a person acting as themselves" do
      ctx = tenant!()

      assert SessionContext.for_actor(ctx.actor) == %{
               tenant: {:named, ctx.organization.name},
               identity: ctx.email,
               impersonator: nil
             }
    end

    test "names the operator behind an impersonating actor" do
      customer = tenant!()
      operator = tenant!(email: "operator-#{System.unique_integer([:positive])}@example.test")

      context = SessionContext.for_actor(Impersonation.acting_as(customer.actor, operator.user))

      assert context.identity == customer.email
      assert context.tenant == {:named, customer.organization.name}
      assert context.impersonator == {:named, operator.email}
    end

    test "an operator id that names nobody is unknown, and impersonation still shows" do
      customer = tenant!()

      for operator_id <- [Ash.UUID.generate(), "not-a-uuid"] do
        context = SessionContext.for_actor(Impersonation.acting_as(customer.actor, operator_id))
        assert context.impersonator == :unknown
      end
    end

    test "an actor with no tenant has none, and one whose tenant cannot be read is unknown" do
      ctx = tenant!()

      no_tenant = ActorContext.attach(ctx.user, %ActorContext{})
      assert SessionContext.for_actor(no_tenant).tenant == :none

      missing = ActorContext.attach(ctx.user, %ActorContext{organization_id: Ash.UUID.generate()})
      assert SessionContext.for_actor(missing).tenant == :unknown
    end

    test "no actor, no band" do
      assert SessionContext.for_actor(nil) == nil
    end
  end

  describe "context_band/1" do
    test "renders the tenant and identity" do
      html =
        band(%{
          tenant: {:named, "Riverside Clinic"},
          identity: "ines@example.com",
          impersonator: nil
        })

      assert text(html, "#context-tenant") =~ "Riverside Clinic"
      assert text(html, "#context-identity") =~ "Signed in as"
      assert text(html, "#context-identity") =~ "ines@example.com"
      assert text(html, "#context-impersonation") == ""
    end

    test "renders impersonation, in the warning colour, with the operator's name" do
      html =
        band(%{
          tenant: {:named, "Riverside Clinic"},
          identity: "ines@example.com",
          impersonator: {:named, "support@example.com"}
        })

      assert text(html, "#context-identity") =~ "Acting as"

      assert text(html, "#context-impersonation[data-impersonator=named]") =~
               "support@example.com"

      assert text(html, "#context-impersonation") =~ "Both are recorded"
      assert html =~ "bg-yellow"
    end

    test "an operator who cannot be named is still shown as impersonation" do
      html =
        band(%{
          tenant: {:named, "Riverside Clinic"},
          identity: "ines@example.com",
          impersonator: :unknown
        })

      assert text(html, "#context-identity") =~ "Acting as"

      assert text(html, "#context-impersonation[data-impersonator=unknown]") =~
               "an operator who could not be named"
    end

    test "a missing or unreadable tenant says so rather than going blank" do
      none = band(%{tenant: :none, identity: "ines@example.com", impersonator: nil})
      unknown = band(%{tenant: :unknown, identity: "ines@example.com", impersonator: nil})

      assert text(none, "#context-tenant[data-tenant=none]") =~ "none"
      assert text(unknown, "#context-tenant[data-tenant=unknown]") =~ "unknown"
    end

    test "an actor with no email is described, not left blank" do
      html = band(%{tenant: :none, identity: nil, impersonator: nil})
      assert text(html, "#context-identity") =~ "an actor with no email"
    end
  end
end
