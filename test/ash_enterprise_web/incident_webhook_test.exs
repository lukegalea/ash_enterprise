defmodule AshEnterpriseWeb.IncidentWebhookTest do
  @moduledoc """
  The whole three-in-the-morning path from the outside (q49): a signed SigNoz alert arrives
  at the inbound alert webhook, opens an incident in the key's organization, and the
  `incident_triage` pack gives the On-call role one triage task. The same rule firing again
  joins the incident; its resolution closes it.

  Refused first: an unsigned delivery and a delivery under another tenant's key open no
  incident here. `test/ash_enterprise/bpmn/incident_triage_pack_test.exs` covers the
  incident and the task in detail; this file covers the seam.
  SYNTHETIC data only.
  """

  # async: false. It swaps the webhook keys in the application env, which is node-global.
  use AshEnterpriseWeb.ConnCase, async: false
  use Oban.Testing, repo: AshEnterprise.Repo

  import AshEnterprise.Test.AssistantFixtures, only: [tenant!: 0]

  require Ash.Query

  alias AshEnterprise.Automation.{AlertWebhook, Incident}
  alias AshEnterprise.Bpmn.{Definition, HumanTask, Subscription}
  alias AshOperations.Webhook.Signature

  setup do
    ours = tenant!()
    theirs = tenant!()

    {:ok, _} =
      Subscription.install_pack("incident_triage", actor: ours.actor, tenant: ours.tenant)

    opts = [actor: ours.actor, tenant: ours.tenant]

    for {resource, key} <- [
          {Definition, "incident.triage"},
          {Subscription, "incident.triage.opened"}
        ] do
      resource
      |> Ash.Query.filter(key == ^key and status == :draft)
      |> Ash.read_one!(authorize?: false, tenant: ours.tenant)
      |> resource.publish!(opts)
    end

    previous = Application.get_env(:ash_enterprise, AlertWebhook)

    Application.put_env(:ash_enterprise, AlertWebhook,
      keys: [
        %{id: "ops-ours", organization_id: ours.tenant, secret: "synthetic-secret-ours"},
        %{id: "ops-theirs", organization_id: theirs.tenant, secret: "synthetic-secret-theirs"}
      ]
    )

    on_exit(fn ->
      if previous,
        do: Application.put_env(:ash_enterprise, AlertWebhook, previous),
        else: Application.delete_env(:ash_enterprise, AlertWebhook)

      AshEnterprise.Hammer.set("webhook:alerts-signoz:127.0.0.1", 60_000, 0)
    end)

    %{ours: ours.tenant, theirs: theirs.tenant}
  end

  defp signoz(status, rule, fingerprint) do
    Jason.encode!(%{
      "receiver" => "ash",
      "status" => status,
      "alerts" => [
        %{
          "status" => status,
          "labels" => %{
            "alertname" => "SLO /health: no probes answered for 10 minutes",
            "ruleId" => rule,
            "severity" => "critical",
            "category" => "availability"
          },
          "startsAt" => "2026-11-13T03:00:00Z",
          "fingerprint" => fingerprint
        }
      ]
    })
  end

  defp deliver(body, opts \\ []) do
    timestamp = Integer.to_string(System.os_time(:second))
    key = Keyword.get(opts, :key, "ops-ours")
    secret = Keyword.get(opts, :secret, "synthetic-secret-ours")

    conn = put_req_header(build_conn(), "content-type", "application/json")

    conn =
      if Keyword.get(opts, :unsigned, false) do
        conn
      else
        conn
        |> put_req_header("x-alert-key", key)
        |> put_req_header("x-alert-timestamp", timestamp)
        |> put_req_header(
          "x-alert-signature",
          Signature.hmac_sha256_hex(secret, [timestamp, ".", body])
        )
      end

    post(conn, "/webhooks/alerts-signoz", body)
  end

  defp incidents(tenant), do: Ash.read!(Incident, authorize?: false, tenant: tenant)

  defp sweep!(tenant) do
    inline = Application.get_env(:ash_bpmn, :oban_testing)
    Application.put_env(:ash_bpmn, :oban_testing, nil)

    try do
      AshBpmn.Triggers.SweepWorker.perform(%Oban.Job{args: %{"tenant" => tenant}})
    after
      Application.put_env(:ash_bpmn, :oban_testing, inline)
    end

    for job <- all_enqueued(worker: AshBpmn.Runtime.AdvanceWorker) do
      perform_job(AshBpmn.Runtime.AdvanceWorker, job.args)
    end
  end

  defp open_tasks(tenant) do
    HumanTask
    |> Ash.Query.filter(status == :open)
    |> Ash.read!(authorize?: false, tenant: tenant)
  end

  test "an unsigned delivery, or one under another tenant's key, opens no incident here", ctx do
    assert deliver(signoz("firing", "rule-x", "fp1"), unsigned: true) |> response(401)
    assert incidents(ctx.ours) == []

    assert deliver(signoz("firing", "rule-x", "fp2"),
             key: "ops-theirs",
             secret: "synthetic-secret-theirs"
           )
           |> response(204)

    sweep!(ctx.ours)
    assert incidents(ctx.ours) == []
    assert open_tasks(ctx.ours) == []
    assert [%{key: "signoz:rule-x"}] = incidents(ctx.theirs)
  end

  test "a signed alert opens one incident and one triage task, a repeat joins it, and its resolution closes it",
       ctx do
    assert deliver(signoz("firing", "rule-h", "fp-a")) |> response(204)
    sweep!(ctx.ours)

    assert [%{key: "signoz:rule-h", status: :open, alert_count: 1, category: "availability"}] =
             incidents(ctx.ours)

    assert [_task] = open_tasks(ctx.ours)

    # The same rule firing again, under a new fingerprint: joined, no second task.
    assert deliver(signoz("firing", "rule-h", "fp-b")) |> response(204)
    sweep!(ctx.ours)

    assert [%{status: :open, alert_count: 2}] = incidents(ctx.ours)
    assert [_task] = open_tasks(ctx.ours)

    assert deliver(signoz("resolved", "rule-h", "fp-b")) |> response(204)
    assert [%{status: :closed, closed_reason: :alert_resolved}] = incidents(ctx.ours)
  end
end
