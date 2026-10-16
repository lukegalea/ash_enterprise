defmodule AshEnterpriseWeb.LinksTest do
  @moduledoc """
  Links everywhere, on the web: the deep link `/app/r/:surface/:id`
  re-authorizes and lands on the registry surface with the record selected;
  surfaces serve server-built links (and related tables) for the signed-in
  person; activating a link navigates to its deep link; and a selection
  writes itself into the URL. SYNTHETIC data only.
  """

  use AshEnterpriseWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import AshEnterprise.Test.DailyFixtures

  require Ash.Query

  alias AshEnterprise.Canonical.{Conversation, Person}

  defp sign_in(conn, user) do
    {:ok, token, _claims} = AshAuthentication.Jwt.token_for_user(user)

    conn
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session("user_token", token)
  end

  defp pushed(view) do
    assert_push_event(view, "a2ui:messages", %{messages: messages}, 5_000)
    messages
  end

  defp data_model(messages) do
    Enum.find_value(messages, fn
      %{"createSurface" => %{"dataModel" => model}} -> model
      %{"updateDataModel" => %{"path" => "/", "value" => model}} -> model
      _other -> nil
    end)
  end

  defp ctx_path(path, context, id),
    do: path <> "?" <> Plug.Conn.Query.encode(%{"ctx" => %{context => id}})

  setup %{conn: conn} do
    ctx = tenant!()
    %{conn: sign_in(conn, ctx.user), ctx: ctx}
  end

  describe "the deep link" do
    test "opens a readable record on its surface, selected", %{conn: conn, ctx: ctx} do
      ada = person!(ctx, "ada@example.test", "Ada Park")

      conn = get(conn, "/app/r/people/#{ada.id}")
      assert redirected_to(conn) == ctx_path("/app/people", "person", ada.id)
    end

    test "a record the person may not read is not found — another tenant's, or none", %{
      conn: conn
    } do
      other = tenant!()
      theirs = person!(other, "theirs@example.test", "Not Yours")

      for id <- [theirs.id, Ash.UUID.generate(), "not-a-uuid"] do
        conn = get(conn, "/app/r/people/#{id}")
        assert redirected_to(conn) == "/app"
        assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "not found, or it is not yours"
      end
    end

    test "a conversation lands on the surface that owns it", %{conn: conn, ctx: ctx} do
      slack = conversation!(ctx, "slack", "#eng", "Deploy is green")

      # A conversation link names the first surface over the resource (the
      # Inbox); a Slack conversation opens in Slack.
      conn = get(conn, "/app/r/inbox/#{slack.id}")
      assert redirected_to(conn) == ctx_path("/app/slack", "conversation", slack.id)
    end

    test "a link that names a second surface over the resource opens there", %{
      conn: conn,
      ctx: ctx
    } do
      ada = person!(ctx, "ada@example.test", "Ada Park")

      # People is the first surface over Person; the golden-records surface
      # keeps a person a link sends it, rather than bouncing it to People.
      conn = get(conn, "/app/r/mdm_golden/#{ada.id}")
      assert redirected_to(conn) == ctx_path("/app/mdm/golden", "person", ada.id)
    end

    test "a typed record reference opens the subject's surface", %{conn: conn, ctx: ctx} do
      brief = brief!(ctx)

      conn = get(conn, "/app/r/record/today:#{brief.id}")
      assert redirected_to(conn) == ctx_path("/app/today", "brief", brief.id)
    end

    test "a closed door is refused, and a surface without a detail opens as itself", %{
      conn: conn,
      ctx: ctx
    } do
      refused = get(conn, "/app/r/erasure/#{Ash.UUID.generate()}")
      assert redirected_to(refused) == "/app"
      assert Phoenix.Flash.get(refused.assigns.flash, :error) =~ "platform operator"

      conn = get(sign_in(build_conn(), ctx.user), "/app/r/roles/anything")
      assert redirected_to(conn) == "/app/roles"
    end

    test "a signed-out visitor is sent to sign in" do
      conn = get(build_conn(), "/app/r/people/#{Ash.UUID.generate()}")
      assert redirected_to(conn) == "/sign-in"
    end
  end

  describe "links on the surfaces" do
    test "a person's detail carries related tables whose rows link out", %{conn: conn, ctx: ctx} do
      event = event!(ctx, "Synthetic planning", 30, 30, organizer: {"ada@example.test", "Ada"})
      thread = conversation!(ctx, "gmail", "Quarterly review", "Thursday works.")

      [ada] =
        Person
        |> Ash.Query.filter(email == "ada@example.test")
        |> Ash.read!(actor: ctx.actor, tenant: ctx.tenant)

      {:ok, view, _html} = live(conn, ctx_path("/app/people", "person", ada.id))
      assert has_element?(view, "#ash-a2ui-surface[phx-hook=AshA2ui]")

      model = view |> pushed() |> data_model()
      assert model["context"]["person"]["value"] == ada.id

      [organized] = model["records"]["organized"]
      assert organized["title"] == "Synthetic planning"

      assert organized["_links"]["title"] == %{
               "surface" => "calendar",
               "recordId" => event.id,
               "label" => "Synthetic planning",
               "href" => "/app/r/calendar/#{event.id}"
             }

      # Ada sent nothing; the thread's sender did, and their detail says so.
      assert model["records"]["sent"] == []

      [sender] =
        Person
        |> Ash.Query.filter(email != "ada@example.test")
        |> Ash.read!(actor: ctx.actor, tenant: ctx.tenant)

      {:ok, view, _html} = live(conn, ctx_path("/app/people", "person", sender.id))
      [sent] = (view |> pushed() |> data_model())["records"]["sent"]
      assert sent["preview"] == "Thursday works."
      assert sent["_links"]["thread"]["href"] == "/app/r/inbox/#{thread.id}"
    end

    test "a thread's messages are a related table whose senders link to People", %{
      conn: conn,
      ctx: ctx
    } do
      thread = conversation!(ctx, "gmail", "Quarterly review", "Thursday works.")

      {:ok, view, _html} = live(conn, ctx_path("/app/inbox", "thread", thread.id))
      [message] = (view |> pushed() |> data_model())["records"]["messages"]

      assert message["preview"] == "Thursday works."
      assert %{"surface" => "people", "label" => "Sender"} = message["_links"]["sender_label"]
    end

    test "an event's attendees are a related table linking to People", %{conn: conn, ctx: ctx} do
      ada = person!(ctx, "ada@example.test", "Ada Park")
      event = event!(ctx, "Synthetic sync", 15, 30)

      AshEnterprise.Canonical.CalendarEvent.upsert_from_source!(
        %{
          external_system: event.external_system,
          external_id: event.external_id,
          title: "Synthetic sync",
          starts_at: event.starts_at,
          ends_at: event.ends_at,
          erasure_scope_id: event.erasure_scope_id,
          owner_id: ctx.user.id,
          owner_type: :user,
          attendees: [%{person_id: ada.id, response_status: "tentative"}]
        },
        tenant: ctx.tenant,
        authorize?: false
      )

      {:ok, view, _html} = live(conn, ctx_path("/app/calendar", "event", event.id))
      [attendee] = (view |> pushed() |> data_model())["records"]["attendees"]

      assert attendee["attendee"] == "Ada Park"
      assert attendee["response_label"] == "Maybe"
      assert attendee["_links"]["attendee"]["href"] == "/app/r/people/#{ada.id}"
    end

    test "activating a link navigates to its deep link", %{conn: conn, ctx: ctx} do
      ada = person!(ctx, "ada@example.test", "Ada Park")
      {:ok, view, _html} = live(conn, "/app/calendar")
      _ = pushed(view)

      render_hook(view, "a2ui:open_surface", %{"surface" => "people", "recordId" => ada.id})
      assert_redirect(view, "/app/r/people/#{ada.id}")
    end

    test "selecting a record writes it into the URL", %{conn: conn, ctx: ctx} do
      ada = person!(ctx, "ada@example.test", "Ada Park")
      {:ok, view, _html} = live(conn, "/app/people")
      _ = pushed(view)

      render_hook(view, "a2ui:action", %{
        "version" => "v1.0",
        "action" => %{
          "name" => "context_select",
          "surfaceId" => "people",
          "sourceComponentId" => "data_grid",
          "timestamp" => DateTime.to_iso8601(DateTime.utc_now()),
          "context" => %{"context" => "person", "value" => ada.id}
        }
      })

      assert_patch(view, ctx_path("/app/people", "person", ada.id))
    end

    test "a Gmail thread's link from a Slack-less inbox stays in the inbox", %{ctx: ctx} do
      gmail = conversation!(ctx, "gmail", "Quarterly review", "Thursday works.")

      assert AshEnterprise.Surfaces.record_surface(Conversation, gmail).key == :inbox
    end
  end
end
