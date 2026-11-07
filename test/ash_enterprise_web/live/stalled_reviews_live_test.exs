defmodule AshEnterpriseWeb.StalledReviewsLiveTest do
  @moduledoc """
  The stalled-reviews surface (`/app/reviews/stalled`, AGT-61), the page that shows
  without chat what the assistant's `stalled_reviews` tool shows in an answer: on the
  seeded clinic, a committee member sees the activation approval that has waited three
  days, under the context band, and a colleague with no grant and no candidacy sees an
  empty table, not the task.
  """

  use AshEnterpriseWeb.ConnCase, async: false

  # The clinic's demo data ingests its licence documents into the evidence store, and
  # seeding it takes most of a minute.
  @moduletag evidence: true
  @moduletag timeout: 240_000

  import Phoenix.LiveViewTest

  require Ecto.Query

  alias AshEnterprise.Credentialing.DemoData
  alias AshEnterprise.Security.ActorContext
  alias AshEnterprise.Showcase.Credentialing, as: Tour
  alias AshEnterprise.Test.AssistantFixtures, as: F

  setup do
    ctx = F.tenant!()
    Map.put(ctx, :clinic, DemoData.populate(ctx.tenant))
  end

  defp sign_in(user) do
    {:ok, token, _claims} = AshAuthentication.Jwt.token_for_user(user)

    build_conn()
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session("user_token", token)
  end

  defp messages(view) do
    assert_push_event(view, "a2ui:messages", %{messages: messages}, 5_000)
    JSON.encode!(messages)
  end

  test "a committee member sees the approval that has waited three days; an outsider does not",
       ctx do
    coordinator =
      ActorContext.attach(
        ctx.clinic.coordinator,
        ActorContext.build(ctx.clinic.coordinator, tenant: ctx.tenant)
      )

    waiting = Enum.find(ctx.clinic.credentials, &(&1.number == "DEMO-SLT-0004"))

    %{task_id: task_id} =
      coordinator |> Tour.activations() |> Enum.find(&(&1.credential_id == waiting.id))

    {1, _} =
      AshEnterprise.Repo.update_all(
        Ecto.Query.from(t in "bpmn_human_tasks", where: t.id == type(^task_id, Ecto.UUID)),
        set: [inserted_at: DateTime.add(DateTime.utc_now(), -3 * 86_400, :second)]
      )

    {:ok, view, html} = live(sign_in(hd(ctx.clinic.committee)), "/app/reviews/stalled")
    assert html =~ "ash-a2ui-surface"
    assert has_element?(view, "#context-band")
    assert messages(view) =~ task_id

    outsider = F.colleague!(ctx)
    {:ok, view, _html} = live(sign_in(outsider.user), "/app/reviews/stalled")
    assert has_element?(view, "#context-band")
    refute messages(view) =~ task_id
  end
end
