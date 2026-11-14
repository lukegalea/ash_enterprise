defmodule AshEnterpriseWeb.AlertWebhookTest do
  @moduledoc """
  The inbound alert webhook (`AshEnterprise.Automation.AlertWebhook`): a SigNoz or GlitchTip
  alert, signed with a key that maps to one organization, recorded as one
  `Automation.Occurrence` there.

  Refusals first, each of which records nothing anywhere: no key configured, an unsigned
  call, a wrong signature, a signature over other bytes, a stale timestamp, a key that does
  not exist, and a call naming another tenant's key while holding this one's secret. A
  replay records nothing new, and a payload naming another organization records into the
  key's own. Then a signed alert records exactly one occurrence.
  SYNTHETIC data only.
  """

  # async: false. It swaps the webhook keys in the application env, which is node-global.
  use AshEnterpriseWeb.ConnCase, async: false

  require Ash.Query

  alias AshEnterprise.Automation.{AlertWebhook, Occurrence}
  alias AshEnterprise.Platform.{Seeder, SystemActor}
  alias AshOperations.Webhook.Signature

  setup do
    a = seed("a")
    b = seed("b")

    previous = Application.get_env(:ash_enterprise, AlertWebhook)

    Application.put_env(:ash_enterprise, AlertWebhook,
      keys: [
        %{id: "ops-a", organization_id: a, secret: "synthetic-secret-a"},
        %{id: "ops-b", organization_id: b, secret: "synthetic-secret-b"}
      ]
    )

    on_exit(fn ->
      if previous,
        do: Application.put_env(:ash_enterprise, AlertWebhook, previous),
        else: Application.delete_env(:ash_enterprise, AlertWebhook)

      for provider <- ["alerts-signoz", "alerts-glitchtip"] do
        AshEnterprise.Hammer.set("webhook:#{provider}:127.0.0.1", 60_000, 0)
      end
    end)

    %{a: a, b: b}
  end

  defp seed(label) do
    n = System.unique_integer([:positive])

    Seeder.seed_tenant(
      unique_name: "alerts-#{label}-#{n}",
      email: "alerts-#{label}-#{n}@example.test"
    ).organization.id
  end

  defp signoz(overrides \\ %{}) do
    alert =
      Map.merge(
        %{
          "status" => "firing",
          "labels" => %{
            "alertname" => "Security: refused sign-ins above 20 in 5 minutes",
            "ruleId" => "rule-#{System.unique_integer([:positive])}",
            "severity" => "warning",
            "category" => "security"
          },
          "annotations" => %{"description" => "SYNTHETIC free text that is never kept"},
          "startsAt" => "2026-11-12T10:00:00Z",
          "fingerprint" => "fp#{System.unique_integer([:positive])}"
        },
        overrides
      )

    Jason.encode!(%{"receiver" => "ash", "status" => alert["status"], "alerts" => [alert]})
  end

  defp deliver(body, opts \\ []) do
    timestamp = Keyword.get(opts, :timestamp, Integer.to_string(System.os_time(:second)))
    secret = Keyword.get(opts, :secret, "synthetic-secret-a")
    key = Keyword.get(opts, :key, "ops-a")
    signed = Keyword.get(opts, :signed, body)

    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")

    conn =
      if Keyword.get(opts, :unsigned, false) do
        conn
      else
        conn
        |> put_req_header("x-alert-key", key)
        |> put_req_header("x-alert-timestamp", timestamp)
        |> put_req_header(
          "x-alert-signature",
          Signature.hmac_sha256_hex(secret, [timestamp, ".", signed])
        )
      end

    post(conn, "/webhooks/#{Keyword.get(opts, :provider, "alerts-signoz")}", body)
  end

  defp occurrences(tenant) do
    Occurrence
    |> Ash.Query.for_read(:read)
    |> Ash.read!(actor: SystemActor.oban(), tenant: tenant)
  end

  defp none!(%{a: a, b: b}) do
    assert occurrences(a) == []
    assert occurrences(b) == []
  end

  describe "refused, recording nothing" do
    test "no key configured is 503", ctx do
      Application.put_env(:ash_enterprise, AlertWebhook, keys: [])
      assert deliver(signoz()) |> response(503)
      none!(ctx)
    end

    test "an unsigned call is 401", ctx do
      assert deliver(signoz(), unsigned: true) |> response(401)
      none!(ctx)
    end

    test "a wrong signature, one over other bytes, and a stale one are 401", ctx do
      body = signoz()

      assert deliver(body, secret: "not-the-secret") |> response(401)
      assert deliver(body, signed: signoz()) |> response(401)

      stale = Integer.to_string(System.os_time(:second) - 3_600)
      assert deliver(body, timestamp: stale) |> response(401)
      none!(ctx)
    end

    test "a key that does not exist is 401", ctx do
      assert deliver(signoz(), key: "ops-z") |> response(401)
      none!(ctx)
    end

    test "another tenant's key, signed with this one's secret, is 401", ctx do
      # A caller holding ops-a's secret cannot reach organization b by naming its key.
      assert deliver(signoz(), key: "ops-b", secret: "synthetic-secret-a") |> response(401)
      none!(ctx)
    end

    test "a body with no alert it can read is 400", ctx do
      assert deliver(Jason.encode!(%{"alerts" => [%{"status" => "pending"}]})) |> response(400)

      assert deliver(Jason.encode!(%{"text" => "no attachments"}), provider: "alerts-glitchtip")
             |> response(400)

      none!(ctx)
    end
  end

  describe "recorded" do
    test "a replay records nothing new", %{a: a} = ctx do
      body = signoz()
      timestamp = Integer.to_string(System.os_time(:second))

      assert deliver(body, timestamp: timestamp) |> response(204)
      assert deliver(body, timestamp: timestamp) |> response(204)

      # A renotification of the same alert, signed afresh, is still the same alert.
      assert deliver(body) |> response(204)

      assert [_one] = occurrences(a)
      assert occurrences(ctx.b) == []
    end

    test "a payload naming another organization records into the key's own", %{a: a, b: b} do
      body =
        signoz(%{
          "labels" => %{
            "alertname" => "SYNTHETIC",
            "category" => "security",
            "organization_id" => b
          },
          "organization_id" => b
        })

      assert deliver(body) |> response(204)

      assert [_one] = occurrences(a)
      assert occurrences(b) == []
    end

    test "a signed SigNoz alert records exactly one occurrence, with labels and nothing else", %{
      a: a,
      b: b
    } do
      body = signoz(%{"fingerprint" => "fp-one", "startsAt" => "2026-11-12T10:00:00Z"})

      assert deliver(body) |> response(204)

      assert [occurrence] = occurrences(a)
      assert occurrences(b) == []

      assert occurrence.type == "alert.firing"
      assert occurrence.source == "urn:ash-enterprise:alerts:signoz"
      assert occurrence.event_id == "signoz:fp-one:2026-11-12T10:00:00Z:firing"

      assert occurrence.data == %{
               "provider" => "signoz",
               "alertname" => "Security: refused sign-ins above 20 in 5 minutes",
               "severity" => "warning",
               "category" => "security",
               "series" => "fp-one",
               "rule_id" =>
                 body |> Jason.decode!() |> get_in(["alerts", Access.at(0), "labels", "ruleId"])
             }

      assert occurrence.subject == nil

      refute inspect(occurrence) =~ "never kept"
    end

    test "two firings of one rule with offset startsAt timestamps record two occurrences", %{
      a: a
    } do
      first = signoz(%{"fingerprint" => "fp-off", "startsAt" => "2026-11-12T10:00:00+05:00"})
      second = signoz(%{"fingerprint" => "fp-off", "startsAt" => "2026-11-12T11:00:00+05:00"})

      assert deliver(first) |> response(204)
      assert deliver(second) |> response(204)

      assert [
               "signoz:fp-off:2026-11-12T05:00:00Z:firing",
               "signoz:fp-off:2026-11-12T06:00:00Z:firing"
             ] =
               a |> occurrences() |> Enum.map(& &1.event_id) |> Enum.sort()
    end

    test "a startsAt that is not a timestamp does not collapse distinct firings", %{a: a} do
      first = signoz(%{"fingerprint" => "fp-raw", "startsAt" => "yesterday at noon"})
      second = signoz(%{"fingerprint" => "fp-raw", "startsAt" => "yesterday at one"})

      assert deliver(first) |> response(204)
      assert deliver(second) |> response(204)

      ids = a |> occurrences() |> Enum.map(& &1.event_id)
      assert length(Enum.uniq(ids)) == 2
      refute Enum.any?(ids, &(&1 =~ "unknown"))
    end

    test "its resolution is a second occurrence", %{a: a} do
      firing = signoz(%{"fingerprint" => "fp-two"})
      resolved = signoz(%{"fingerprint" => "fp-two", "status" => "resolved"})

      assert deliver(firing) |> response(204)
      assert deliver(resolved) |> response(204)

      assert ["alert.firing", "alert.resolved"] =
               a |> occurrences() |> Enum.map(& &1.type) |> Enum.sort()
    end

    test "a signed GlitchTip alert records exactly one occurrence per issue", %{a: a, b: b} do
      body =
        Jason.encode!(%{
          "alias" => "GlitchTip",
          "text" => "GlitchTip Alert",
          "attachments" => [
            %{
              "title" => "SYNTHETIC: RuntimeError in a job",
              "title_link" => "https://errors.example.test/acme/issues/4521",
              "text" => "free text that is never kept"
            }
          ]
        })

      assert deliver(body,
               provider: "alerts-glitchtip",
               key: "ops-b",
               secret: "synthetic-secret-b"
             )
             |> response(204)

      assert occurrences(a) == []
      assert [occurrence] = occurrences(b)
      assert occurrence.type == "alert.firing"
      assert occurrence.subject == nil
      assert occurrence.data["rule_id"] == "issue:4521"
      assert occurrence.data["category"] == "error"
      refute inspect(occurrence) =~ "never kept"
    end
  end
end
