defmodule AshEnterprise.Integration.NangoEdgeTest do
  @moduledoc """
  The provider edge (ADR 0011 / AST-155): declared operation → generic action
  → Nango proxy request, with the connection derived from the actor.

  No network: every request is answered by a `Req.Test` stub, and every
  payload is synthetic, shaped from the providers' public API references.
  `NANGO_SECRET_KEY` is set to a fake value for the duration of each test.
  """

  # Application env and the OS environment are global.
  use AshEnterprise.DataCase, async: false

  alias AshEnterprise.Integration.Gmail
  alias AshEnterprise.Integration.GoogleCalendar
  alias AshEnterprise.Integration.GoogleSheets
  alias AshEnterprise.Integration.Landing
  alias AshEnterprise.Integration.LinkedAccount
  alias AshEnterprise.Integration.Nango.{Info, Proxy}
  alias AshEnterprise.Integration.Nango.Verifiers.NoConnectionParams
  alias AshEnterprise.Integration.{ProxyError, Slack, SourceRecord}
  alias AshEnterprise.Security.ActorContext
  alias AshEnterprise.Security.ActorContext.Grant

  @stub Proxy
  @fake_secret "nango-test-secret-not-a-real-key"
  @nango_env AshEnterprise.Integration.Nango
  @landing_env AshEnterprise.Integration.Landing

  setup do
    previous_secret = System.get_env("NANGO_SECRET_KEY")
    previous_nango = Application.get_env(:ash_enterprise, @nango_env)
    previous_landing = Application.get_env(:ash_enterprise, @landing_env)
    test_pid = self()

    System.put_env("NANGO_SECRET_KEY", @fake_secret)

    Application.put_env(:ash_enterprise, @nango_env,
      base_url: "http://nango.test",
      req_options: [plug: {Req.Test, @stub}],
      sleep: fn ms -> send(test_pid, {:slept, ms}) end,
      base_backoff_ms: 10,
      max_attempts: 3,
      max_retry_delay_ms: 5_000
    )

    on_exit(fn ->
      restore_os_env("NANGO_SECRET_KEY", previous_secret)
      restore_app_env(@nango_env, previous_nango)
      restore_app_env(@landing_env, previous_landing)
    end)

    org = organization("nango-edge")
    alice = user(org, "alice")
    bob = user(org, "bob")

    alice_cal = link!(alice, "google-calendar", "conn-cal-alice-synthetic")
    bob_cal = link!(bob, "google-calendar", "conn-cal-bob-synthetic")
    alice_mail = link!(alice, "google-mail", "conn-mail-alice-synthetic")
    alice_slack = link!(alice, "slack", "conn-slack-alice-synthetic")

    %{
      org: org,
      alice: alice,
      bob: bob,
      alice_cal: alice_cal,
      bob_cal: bob_cal,
      alice_mail: alice_mail,
      alice_slack: alice_slack
    }
  end

  describe "action → proxy request shape" do
    test "events.list goes through /proxy with the connection headers and bearer secret", ctx do
      test_pid = self()

      Req.Test.stub(@stub, fn conn ->
        send(test_pid, {:request, request_summary(conn)})
        Req.Test.json(conn, synthetic_events_page())
      end)

      assert {:ok, body} =
               GoogleCalendar.list_events(
                 %{
                   calendar_id: "primary",
                   sync_token: "sync-token-synthetic-1",
                   max_results: 50,
                   single_events: false
                 },
                 actor: ctx.alice
               )

      assert body == synthetic_events_page()

      assert_received {:request, request}
      assert request.method == "GET"
      assert request.host == "nango.test"
      assert request.path == "/proxy/calendar/v3/calendars/primary/events"

      assert request.query == [
               {"syncToken", "sync-token-synthetic-1"},
               {"maxResults", "50"},
               {"singleEvents", "false"}
             ]

      assert request.provider_config_key == ["google-calendar"]
      assert request.connection_id == ["conn-cal-alice-synthetic"]
      assert request.authorization == ["Bearer " <> @fake_secret]
    end

    test "Gmail messages.get: metadata by default, repeated metadataHeaders, id is one segment",
         ctx do
      test_pid = self()

      Req.Test.stub(@stub, fn conn ->
        send(test_pid, {:request, request_summary(conn)})
        Req.Test.json(conn, %{"id" => "18c0synthetic", "labelIds" => ["INBOX"]})
      end)

      assert {:ok, %{"id" => "18c0synthetic"}} =
               Gmail.get_message(
                 %{id: "18c0/synthetic", metadata_headers: ["From", "Subject"]},
                 actor: ctx.alice
               )

      assert_received {:request, request}
      assert request.path == "/proxy/gmail/v1/users/me/messages/18c0%2Fsynthetic"
      assert request.connection_id == ["conn-mail-alice-synthetic"]
      assert request.provider_config_key == ["google-mail"]

      assert request.query == [
               {"format", "metadata"},
               {"metadataHeaders", "From"},
               {"metadataHeaders", "Subject"}
             ]
    end

    test "a dot-segment path value is refused before any request", ctx do
      tripwire_stub()

      assert {:error, error} = Gmail.get_message(%{id: ".."}, actor: ctx.alice)
      assert ProxyError.reason(error) == :bad_request
      refute_received :http_called
    end

    test "Slack conversations.history passes channel, cursor and oldest", ctx do
      test_pid = self()

      Req.Test.stub(@stub, fn conn ->
        send(test_pid, {:request, request_summary(conn)})
        Req.Test.json(conn, synthetic_slack_history())
      end)

      assert {:ok, %{"ok" => true, "messages" => [_]}} =
               Slack.conversation_history(
                 %{
                   channel: "C0SYNTH01",
                   cursor: "dXNlcjpVMEc5V0ZYTlo=",
                   oldest: "1712345678.000100"
                 },
                 actor: ctx.alice
               )

      assert_received {:request, request}
      assert request.path == "/proxy/conversations.history"
      assert request.provider_config_key == ["slack"]
      assert request.connection_id == ["conn-slack-alice-synthetic"]

      assert request.query == [
               {"channel", "C0SYNTH01"},
               {"cursor", "dXNlcjpVMEc5V0ZYTlo="},
               {"oldest", "1712345678.000100"}
             ]
    end

    test "every declared operation is a generic action with a code interface" do
      for resource <- [GoogleCalendar, Gmail, Slack, GoogleSheets],
          operation <- Info.operations(resource) do
        action = Ash.Resource.Info.action(resource, operation.name)
        assert action.type == :action, "#{inspect(resource)}.#{operation.name}"
        assert function_exported?(resource, operation.name, 2)
      end

      assert Enum.map(Info.operations(GoogleCalendar), & &1.name) == [
               :list_calendars,
               :list_events
             ]

      assert Enum.map(Info.operations(Gmail), & &1.name) == [
               :get_profile,
               :list_history,
               :list_messages,
               :get_message
             ]

      assert Enum.map(Info.operations(Slack), & &1.name) ==
               [:user_conversations, :conversation_history, :user_info]

      assert Enum.map(Info.operations(GoogleSheets), & &1.name) == [:batch_get_values]
    end

    test "Sheets values.batchGet: repeated ranges, and fractional numbers decode as Decimal",
         ctx do
      test_pid = self()
      link!(ctx.alice, "google-sheet", "conn-sheet-alice-synthetic")

      # Raw JSON, so the amounts reach the decoder as JSON numbers.
      Req.Test.stub(@stub, fn conn ->
        send(test_pid, {:request, request_summary(conn)})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, ~s({"spreadsheetId":"sheet-synthetic","valueRanges":[
          {"range":"Sheet1!A1:B2","majorDimension":"ROWS","values":[["Coffee",-4.35],["Units",3]]},
          {"range":"Sheet2!A1:A1","majorDimension":"ROWS","values":[[0.1]]}]}))
      end)

      assert {:ok, body} =
               GoogleSheets.batch_get_values(
                 %{
                   spreadsheet_id: "sheet-synthetic",
                   ranges: ["Sheet1!A1:B2", "Sheet2!A1:A1"],
                   value_render_option: "UNFORMATTED_VALUE",
                   date_time_render_option: "SERIAL_NUMBER"
                 },
                 actor: ctx.alice
               )

      assert [first, second] = body["valueRanges"]
      assert first["values"] == [["Coffee", Decimal.new("-4.35")], ["Units", 3]]
      assert second["values"] == [[Decimal.new("0.1")]]

      assert_received {:request, request}
      assert request.path == "/proxy/v4/spreadsheets/sheet-synthetic/values:batchGet"
      assert {"ranges", "Sheet1!A1:B2"} in request.query
      assert {"ranges", "Sheet2!A1:A1"} in request.query
      assert {"valueRenderOption", "UNFORMATTED_VALUE"} in request.query
      assert request.provider_config_key == ["google-sheet"]
      assert request.connection_id == ["conn-sheet-alice-synthetic"]
    end

    test "an operation without numbers: :decimal still decodes fractions as floats", ctx do
      Req.Test.stub(@stub, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          ~s({"items":[],"nextSyncToken":"t","accessRole":"owner","x":0.5})
        )
      end)

      assert {:ok, %{"x" => 0.5}} =
               GoogleCalendar.list_events(%{calendar_id: "primary"}, actor: ctx.alice)
    end
  end

  describe "the connection is derived from the actor" do
    test "the same action spends each actor's own connection", ctx do
      test_pid = self()

      Req.Test.stub(@stub, fn conn ->
        send(test_pid, {:connection, Plug.Conn.get_req_header(conn, "connection-id")})
        Req.Test.json(conn, %{"items" => []})
      end)

      assert {:ok, _} = GoogleCalendar.list_calendars(%{}, actor: ctx.alice)
      assert_received {:connection, ["conn-cal-alice-synthetic"]}

      assert {:ok, _} = GoogleCalendar.list_calendars(%{}, actor: ctx.bob)
      assert_received {:connection, ["conn-cal-bob-synthetic"]}
    end

    test "no generated action has a connection or provider-config argument" do
      for resource <- [GoogleCalendar, Gmail, Slack],
          action <- Ash.Resource.Info.actions(resource),
          argument <- action.arguments do
        refute argument.name in [:connection_id, :connection, :provider_config_key],
               "#{inspect(resource)}.#{action.name} accepts #{argument.name}"
      end
    end

    test "a caller-supplied connection id is rejected as an unknown input", ctx do
      tripwire_stub()

      assert {:error, %Ash.Error.Invalid{} = error} =
               GoogleCalendar.list_calendars(
                 %{connection_id: "conn-cal-bob-synthetic"},
                 actor: ctx.alice
               )

      assert Enum.any?(error.errors, &match?(%Ash.Error.Invalid.NoSuchInput{}, &1))
      refute_received :http_called
    end

    test "linked_account_id cannot reach another actor's linked account", ctx do
      tripwire_stub()

      assert {:error, error} =
               GoogleCalendar.list_calendars(%{linked_account_id: ctx.bob_cal.id},
                 actor: ctx.alice
               )

      assert ProxyError.reason(error) == :no_linked_account
      refute_received :http_called
    end

    test "several linked accounts: ambiguous without linked_account_id, exact with it", ctx do
      personal = link!(ctx.alice, "google-calendar", "conn-cal-alice-personal-synthetic")
      test_pid = self()

      Req.Test.stub(@stub, fn conn ->
        send(test_pid, {:connection, Plug.Conn.get_req_header(conn, "connection-id")})
        Req.Test.json(conn, %{"items" => []})
      end)

      assert {:error, error} = GoogleCalendar.list_calendars(%{}, actor: ctx.alice)
      assert ProxyError.reason(error) == :ambiguous_linked_account

      assert {:ok, _} =
               GoogleCalendar.list_calendars(%{linked_account_id: personal.id}, actor: ctx.alice)

      assert_received {:connection, ["conn-cal-alice-personal-synthetic"]}
    end

    test "a deactivated linked account is never resolved", ctx do
      ctx.bob_cal
      |> Ash.Changeset.for_update(:deactivate, %{}, authorize?: false, tenant: ctx.org.id)
      |> Ash.update!()

      assert {:error, error} = GoogleCalendar.list_calendars(%{}, actor: ctx.bob)
      assert ProxyError.reason(error) == :no_linked_account
    end

    test "a system actor passes the operation policy but owns no connection", ctx do
      tripwire_stub()

      assert {:error, error} =
               GoogleCalendar.list_calendars(%{linked_account_id: ctx.alice_cal.id},
                 actor: AshEnterprise.Platform.SystemActor.oban()
               )

      assert ProxyError.reason(error) == :no_linked_account
      refute_received :http_called
    end

    test "mine/1 lists only the actor's own linked accounts", ctx do
      assert {:ok, accounts} =
               LinkedAccount.mine("google-calendar", actor: ctx.alice, tenant: ctx.org.id)

      assert Enum.map(accounts, & &1.id) == [ctx.alice_cal.id]
    end

    test "the verifier refuses an operation that declares a connection param" do
      dsl = GoogleCalendar.spark_dsl_config()
      [operation | _] = Info.operations(dsl)

      bad_param = %AshEnterprise.Integration.Nango.Param{
        name: :connection_id,
        type: :string,
        as: "Connection-Id"
      }

      bad_dsl =
        Spark.Dsl.Transformer.replace_entity(
          dsl,
          [:nango],
          %{operation | params: [bad_param | operation.params]},
          &(&1.name == operation.name)
        )

      assert :ok = NoConnectionParams.verify(dsl)

      assert {:error, %Spark.Error.DslError{message: message}} =
               NoConnectionParams.verify(bad_dsl)

      assert message =~ "never an argument"
    end
  end

  describe "authorization" do
    test "an actor without a grant on the operation resource is forbidden, and nothing is sent",
         ctx do
      tripwire_stub()

      no_calendar =
        actor(ctx.alice, ctx.org, Map.delete(grants(), {inspect(GoogleCalendar), :read}))

      assert {:error, %Ash.Error.Forbidden{}} =
               GoogleCalendar.list_calendars(%{}, actor: no_calendar)

      refute_received :http_called
    end

    test "basic depth on an unowned operation resource does not authorize", ctx do
      basic_only =
        actor(
          ctx.alice,
          ctx.org,
          Map.put(grants(), {inspect(GoogleCalendar), :read}, %Grant{basic?: true})
        )

      assert {:error, %Ash.Error.Forbidden{}} =
               GoogleCalendar.list_calendars(%{}, actor: basic_only)
    end

    test "an actor who cannot read linked accounts resolves no connection", ctx do
      tripwire_stub()

      no_links = actor(ctx.alice, ctx.org, Map.delete(grants(), {inspect(LinkedAccount), :read}))

      assert {:error, error} = GoogleCalendar.list_calendars(%{}, actor: no_links)
      assert ProxyError.reason(error) == :no_linked_account
      refute_received :http_called
    end

    test "Ash.can? answers the operation question without calling out", ctx do
      assert Ash.can?({GoogleCalendar, :list_events, %{calendar_id: "primary"}}, ctx.alice)

      no_calendar =
        actor(ctx.alice, ctx.org, Map.delete(grants(), {inspect(GoogleCalendar), :read}))

      refute Ash.can?({GoogleCalendar, :list_events, %{calendar_id: "primary"}}, no_calendar)
    end
  end

  describe "typed errors" do
    test "410 from Calendar surfaces as :gone (sync token invalid)", ctx do
      Req.Test.stub(@stub, fn conn ->
        conn
        |> Plug.Conn.put_status(410)
        |> Req.Test.json(google_error(410, "fullSyncRequired", "GONE"))
      end)

      assert {:error, error} =
               GoogleCalendar.list_events(
                 %{calendar_id: "primary", sync_token: "expired-sync-token-synthetic"},
                 actor: ctx.alice
               )

      assert %ProxyError{reason: :gone, status: 410, provider_code: "fullSyncRequired"} =
               ProxyError.unwrap(error)

      assert ProxyError.unwrap(error).integration == "google-calendar"
      assert ProxyError.unwrap(error).operation == :list_events
    end

    test "401 is :unauthorized and 404 is :not_found", ctx do
      Req.Test.stub(@stub, fn conn ->
        case conn.request_path do
          "/proxy/gmail/v1/users/me/profile" ->
            conn
            |> Plug.Conn.put_status(401)
            |> Req.Test.json(google_error(401, "authError", "UNAUTHENTICATED"))

          _ ->
            conn
            |> Plug.Conn.put_status(404)
            |> Req.Test.json(google_error(404, "notFound", "NOT_FOUND"))
        end
      end)

      assert {:error, e1} = Gmail.get_profile(%{}, actor: ctx.alice)
      assert ProxyError.reason(e1) == :unauthorized

      assert {:error, e2} = Gmail.list_history(%{start_history_id: "1"}, actor: ctx.alice)
      assert ProxyError.reason(e2) == :not_found
    end

    test "Nango's own unknown_connection is not mistaken for a provider 404", ctx do
      Req.Test.stub(@stub, fn conn ->
        conn
        |> Plug.Conn.put_status(404)
        |> Req.Test.json(%{
          "error" => %{"code" => "unknown_connection", "message" => "synthetic"}
        })
      end)

      assert {:error, error} = Gmail.list_history(%{start_history_id: "1"}, actor: ctx.alice)

      assert %ProxyError{reason: :connection_not_found, provider_code: "unknown_connection"} =
               ProxyError.unwrap(error)
    end

    test "Slack ok:false bodies are classified by error code", ctx do
      Req.Test.stub(@stub, fn conn ->
        Req.Test.json(conn, %{"ok" => false, "error" => "invalid_auth"})
      end)

      assert {:error, error} = Slack.user_info(%{user: "U0SYNTH01"}, actor: ctx.alice)

      assert %ProxyError{reason: :unauthorized, provider_code: "invalid_auth"} =
               ProxyError.unwrap(error)
    end

    test "no secret, connection id or body content in the error", ctx do
      Req.Test.stub(@stub, fn conn ->
        conn
        |> Plug.Conn.put_status(403)
        |> Req.Test.json(google_error(403, "insufficientPermissions", "PERMISSION_DENIED"))
      end)

      assert {:error, error} = GoogleCalendar.list_calendars(%{}, actor: ctx.alice)
      assert ProxyError.reason(error) == :forbidden

      rendered = inspect(error) <> Exception.message(error)
      refute rendered =~ @fake_secret
      refute rendered =~ "conn-cal-alice-synthetic"
      refute rendered =~ "synthetic error message"
    end

    test "an unset NANGO_SECRET_KEY is :not_configured and sends nothing", ctx do
      System.delete_env("NANGO_SECRET_KEY")
      tripwire_stub()

      assert {:error, error} = GoogleCalendar.list_calendars(%{}, actor: ctx.alice)
      assert ProxyError.reason(error) == :not_configured
      refute_received :http_called
    end
  end

  describe "429 retry" do
    test "honours Retry-After, then succeeds", ctx do
      calls = :counters.new(1, [])

      Req.Test.stub(@stub, fn conn ->
        :counters.add(calls, 1, 1)

        if :counters.get(calls, 1) == 1 do
          conn
          |> Plug.Conn.put_resp_header("retry-after", "2")
          |> Plug.Conn.put_status(429)
          |> Req.Test.json(%{"ok" => false, "error" => "ratelimited"})
        else
          Req.Test.json(conn, %{
            "ok" => true,
            "channels" => [],
            "response_metadata" => %{"next_cursor" => ""}
          })
        end
      end)

      assert {:ok, %{"ok" => true}} = Slack.user_conversations(%{limit: 200}, actor: ctx.alice)
      assert :counters.get(calls, 1) == 2
      assert_received {:slept, 2000}
    end

    test "backs off exponentially without Retry-After and gives up as :rate_limited", ctx do
      calls = :counters.new(1, [])

      Req.Test.stub(@stub, fn conn ->
        :counters.add(calls, 1, 1)

        conn
        |> Plug.Conn.put_status(429)
        |> Req.Test.json(google_error(429, "rateLimitExceeded", "RESOURCE_EXHAUSTED"))
      end)

      assert {:error, error} = GoogleCalendar.list_calendars(%{}, actor: ctx.alice)
      assert %ProxyError{reason: :rate_limited, status: 429} = ProxyError.unwrap(error)
      assert :counters.get(calls, 1) == 3
      assert_received {:slept, 10}
      assert_received {:slept, 20}
    end

    test "Google's 403 rateLimitExceeded is retried like a 429", ctx do
      calls = :counters.new(1, [])

      Req.Test.stub(@stub, fn conn ->
        :counters.add(calls, 1, 1)

        if :counters.get(calls, 1) == 1 do
          conn
          |> Plug.Conn.put_status(403)
          |> Req.Test.json(google_error(403, "userRateLimitExceeded", "PERMISSION_DENIED"))
        else
          Req.Test.json(conn, %{"emailAddress" => "operator@example.test", "historyId" => "1001"})
        end
      end)

      assert {:ok, %{"historyId" => "1001"}} = Gmail.get_profile(%{}, actor: ctx.alice)
      assert :counters.get(calls, 1) == 2
    end

    test "a Retry-After beyond the cap is not slept: :rate_limited carries retry_after_ms", ctx do
      calls = :counters.new(1, [])

      Req.Test.stub(@stub, fn conn ->
        :counters.add(calls, 1, 1)

        conn
        |> Plug.Conn.put_resp_header("retry-after", "120")
        |> Plug.Conn.put_status(429)
        |> Req.Test.json(%{})
      end)

      assert {:error, error} = Slack.user_info(%{user: "U0SYNTH01"}, actor: ctx.alice)

      assert %ProxyError{reason: :rate_limited, retry_after_ms: 120_000} =
               ProxyError.unwrap(error)

      assert :counters.get(calls, 1) == 1
      refute_received {:slept, _}
    end

    test "Retry-After as an HTTP date is honoured" do
      at =
        DateTime.utc_now()
        |> DateTime.add(3, :second)
        |> Calendar.strftime("%a, %d %b %Y %H:%M:%S GMT")

      ms = Proxy.retry_after_ms(%{"retry-after" => [at]})
      assert ms in 1_000..3_000
    end
  end

  describe "landing" do
    test "with no lander configured, nothing lands", ctx do
      Application.put_env(:ash_enterprise, @landing_env, [])

      refute Landing.wired?()

      assert {:error, :scoped_landing_not_wired} =
               Landing.land(synthetic_record(), scope: Landing.scope(ctx.alice_cal))

      assert {:error, :scoped_landing_not_wired} = Landing.open(ctx.alice_cal)
    end

    test "a scope is required" do
      assert {:error, :scope_required} = Landing.land(synthetic_record(), [])
    end

    test "the configured lander receives the record and the linked account's scope", ctx do
      Application.put_env(:ash_enterprise, @landing_env,
        lander: AshEnterprise.Integration.NangoEdgeTest.CapturingLander
      )

      Process.put(:landed_to, self())
      record = synthetic_record()
      scope = Landing.scope(ctx.alice_cal)

      assert {:ok, :captured} = Landing.land(record, scope: scope)
      assert_received {:landed, ^record, ^scope}
      assert scope == ctx.alice_cal.id
      refute scope =~ "conn-"
    end
  end

  # --- fixtures (synthetic, shaped from the public API references) -------------

  defp synthetic_events_page do
    %{
      "kind" => "calendar#events",
      "items" => [
        %{
          "id" => "evtsynthetic001",
          "status" => "confirmed",
          "summary" => "Synthetic planning block",
          "start" => %{"dateTime" => "2026-10-13T09:00:00Z"},
          "end" => %{"dateTime" => "2026-10-13T09:30:00Z"}
        }
      ],
      "nextSyncToken" => "sync-token-synthetic-2"
    }
  end

  defp synthetic_slack_history do
    %{
      "ok" => true,
      "messages" => [
        %{
          "type" => "message",
          "user" => "U0SYNTH01",
          "text" => "synthetic",
          "ts" => "1712345679.000200"
        }
      ],
      "has_more" => false,
      "response_metadata" => %{"next_cursor" => ""}
    }
  end

  defp google_error(code, reason, status) do
    %{
      "error" => %{
        "code" => code,
        "message" => "synthetic error message",
        "status" => status,
        "errors" => [
          %{"domain" => "global", "reason" => reason, "message" => "synthetic error message"}
        ]
      }
    }
  end

  defp synthetic_record do
    %SourceRecord{
      external_system: "google_calendar",
      external_id: "evtsynthetic001",
      stream: "events",
      raw_payload: hd(synthetic_events_page()["items"]),
      cursor: %{"nextSyncToken" => "sync-token-synthetic-2"},
      fetched_at: ~U[2026-10-12 12:00:00Z]
    }
  end

  defmodule CapturingLander do
    @moduledoc false
    @behaviour AshEnterprise.Integration.Landing

    @impl true
    def land(record, scope_ref) do
      send(Process.get(:landed_to), {:landed, record, scope_ref})
      {:ok, :captured}
    end
  end

  # --- helpers -----------------------------------------------------------------

  # A stub for tests that must not reach the network at all: any request
  # trips `:http_called`, which the test then refutes.
  defp tripwire_stub do
    test_pid = self()

    Req.Test.stub(@stub, fn conn ->
      send(test_pid, :http_called)
      Req.Test.json(conn, %{})
    end)
  end

  defp request_summary(conn) do
    %{
      method: conn.method,
      host: conn.host,
      path: conn.request_path,
      query: conn.query_string |> URI.query_decoder() |> Enum.to_list(),
      provider_config_key: Plug.Conn.get_req_header(conn, "provider-config-key"),
      connection_id: Plug.Conn.get_req_header(conn, "connection-id"),
      authorization: Plug.Conn.get_req_header(conn, "authorization")
    }
  end

  # The grants a dogfood operator holds: Basic on their own linked accounts,
  # Global read (= may call) on each operation resource. Built directly, the
  # way `LoadActorContext` would precompute them — policy checks never query.
  defp grants do
    %{
      {inspect(LinkedAccount), :read} => %Grant{basic?: true},
      {inspect(LinkedAccount), :create} => %Grant{basic?: true},
      {inspect(GoogleCalendar), :read} => %Grant{global?: true},
      {inspect(Gmail), :read} => %Grant{global?: true},
      {inspect(Slack), :read} => %Grant{global?: true},
      {inspect(GoogleSheets), :read} => %Grant{global?: true}
    }
  end

  defp actor(user, org, grants \\ grants()) do
    ActorContext.attach(user, %ActorContext{
      user_id: user.id,
      organization_id: org.id,
      principal_ids: [user.id],
      grants: grants
    })
  end

  defp organization(name) do
    unique = "#{name}-#{System.unique_integer([:positive])}"

    AshEnterprise.Accounts.Organization
    |> Ash.Changeset.for_create(:create, %{name: unique, unique_name: unique}, authorize?: false)
    |> Ash.create!()
  end

  defp user(org, name) do
    AshEnterprise.Accounts.User
    |> Ash.Changeset.for_create(
      :register_with_password,
      %{
        email: "#{name}-#{System.unique_integer([:positive])}@nango-edge.test",
        password: "password1234",
        password_confirmation: "password1234"
      },
      authorize?: false
    )
    |> Ash.create!()
    |> actor(org)
  end

  defp link!(actor, provider_config_key, connection_id) do
    LinkedAccount.link!(
      %{provider_config_key: provider_config_key, connection_id: connection_id},
      actor: actor,
      tenant: ActorContext.tenant(actor)
    )
  end

  defp restore_os_env(name, nil), do: System.delete_env(name)
  defp restore_os_env(name, value), do: System.put_env(name, value)

  defp restore_app_env(key, nil), do: Application.delete_env(:ash_enterprise, key)
  defp restore_app_env(key, value), do: Application.put_env(:ash_enterprise, key, value)
end
