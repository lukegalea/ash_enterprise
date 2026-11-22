defmodule AshEnterpriseWeb.QuestionProposalsLiveTest do
  @moduledoc """
  The question-proposals surface (`/app/judgments/question-proposals`,
  S1-75) through the real LiveView, as the signed-in person clicks it: the
  proposals awaiting confirmation, each question in full, and **Confirm
  questions**, which is the person's own act. An agent or a system actor
  cannot confirm, and a confirmed proposal offers no confirm.
  """

  use AshEnterpriseWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias AshEnterprise.Platform.Correlation
  alias AshEnterprise.Platform.Seeder
  alias AshEnterprise.Platform.SystemActor
  alias AshEnterprise.Security.ActorContext
  alias AshEnterprise.SystemOne.QuestionProposal
  alias AshEnterpriseWeb.A2ui.Judgments.QuestionProposalsUI

  @path "/app/judgments/question-proposals"
  @fixtures_dir Path.expand("../../fixtures/system_one/policy", __DIR__)
  @policy_text File.read!(Path.join(@fixtures_dir, "code_standards_excerpt.md"))
  @valid_output File.read!(Path.join(@fixtures_dir, "recordings/valid.json"))

  setup %{conn: conn} do
    Correlation.start_new()
    n = System.unique_integer([:positive])

    %{organization: organization, user: admin} =
      Seeder.seed_tenant(name: "Question proposals #{n}", unique_name: "question-proposals-#{n}")

    %{
      conn: sign_in(conn, admin),
      org: organization.id,
      person: ActorContext.attach(admin, ActorContext.build(admin, tenant: organization.id))
    }
  end

  defp sign_in(conn, user) do
    {:ok, token, _claims} = AshAuthentication.Jwt.token_for_user(user)

    conn
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session("user_token", token)
  end

  # Drafted by the fixed test instrument (no model call), as tooling would.
  defp proposal!(ctx) do
    {:ok, proposal} =
      QuestionProposal.propose(
        source: "test/fixtures/system_one/policy/code_standards_excerpt.md",
        policy_text: @policy_text,
        profile: :laya_cpu,
        transport: {:fixed, @valid_output},
        actor: SystemActor.system(),
        tenant: ctx.org
      )

    proposal
  end

  defp pushed(view) do
    assert_push_event(view, "a2ui:messages", %{messages: messages}, 5_000)
    messages
  end

  defp action(view, name, context) do
    render_hook(
      view,
      "a2ui:message",
      AshEnterprise.A2uiMessage.ash_action("judgment_question_proposals", name, context,
        source: "table"
      )
    )

    pushed(view)
  end

  defp confirm(view, proposal) do
    action(view, "invoke", %{
      "action" => "confirm",
      "recordId" => proposal.id,
      "component" => "table"
    })
  end

  defp rows(messages) do
    Enum.find_value(messages, [], fn
      %{"createSurface" => %{"dataModel" => %{"records" => rows}}} when is_list(rows) -> rows
      %{"updateDataModel" => %{"path" => "/records", "value" => rows}} when is_list(rows) -> rows
      _other -> nil
    end)
  end

  defp feedback(messages) do
    Enum.find_value(messages, fn
      %{"updateDataModel" => %{"path" => "/ui/feedback", "value" => value}} -> value
      _other -> nil
    end)
  end

  defp detail(messages) do
    Enum.find_value(messages, fn
      %{"updateDataModel" => %{"path" => "/detail/proposal", "value" => value}} -> value
      _other -> nil
    end)
  end

  defp status(proposal), do: Ash.reload!(proposal, authorize?: false).status

  test "the surface lists the proposals awaiting confirmation, with their questions", ctx do
    proposal = proposal!(ctx)

    {:ok, view, _html} = live(ctx.conn, @path)
    assert has_element?(view, "#ash-a2ui-surface")

    assert [row] = rows(pushed(view))
    assert row["id"] == proposal.id
    assert row["source"] == "test/fixtures/system_one/policy/code_standards_excerpt.md"
    assert row["question_names"] == "commit_message_imperative, test_sleeps"
  end

  test "Details shows each question's wording, answers, criteria and state shape", ctx do
    proposal = proposal!(ctx)
    {:ok, view, _html} = live(ctx.conn, @path)
    _ = pushed(view)

    shown =
      view
      |> action("context_select", %{"context" => "proposal", "value" => proposal.id})
      |> detail()

    questions = shown["questions"]
    assert questions =~ "commit_message_imperative (clause std-1, family standards_commits)"
    assert questions =~ "Asks: Does the commit message use the imperative mood"
    assert questions =~ "Answers: one of imperative, other"
    assert questions =~ "imperative: The message states the change as a command"
    assert questions =~ "test_sleeps (clause std-2, family standards_tests)"
    assert questions =~ "Answers: yes or no"
    assert questions =~ "State shape: none"
  end

  test "Confirm questions confirms as the person, and the proposal leaves the list", ctx do
    proposal = proposal!(ctx)
    {:ok, view, _html} = live(ctx.conn, @path)
    _ = pushed(view)

    messages = confirm(view, proposal)

    assert feedback(messages)["kind"] == "success"
    confirmed = Ash.reload!(proposal, authorize?: false)
    assert confirmed.status == :confirmed

    # Re-validated and re-hashed: the declaration is the wording the person read.
    assert Enum.map(confirmed.proposals, & &1["question_hash"]) ==
             Enum.map(proposal.proposals, & &1["question_hash"])

    {:ok, reopened, _html} = live(ctx.conn, @path)
    assert rows(pushed(reopened)) == []
  end

  test "an agent or a system actor cannot confirm", ctx do
    proposal = proposal!(ctx)

    for actor <- [SystemActor.ai(), SystemActor.process(), SystemActor.system()] do
      {:error, messages} =
        AshA2ui.ActionHandler.handle(
          QuestionProposalsUI,
          AshEnterprise.A2uiMessage.ash_action(QuestionProposalsUI, "invoke", %{
            "action" => "confirm",
            "recordId" => proposal.id,
            "component" => "table"
          }),
          actor: actor,
          tenant: ctx.org
        )

      assert feedback(messages)["kind"] == "error", inspect(actor)
      assert status(proposal) == :proposed
    end
  end

  test "a confirmed proposal shows no confirm, and a click on it is refused", ctx do
    proposal = proposal!(ctx)

    {:ok, _} =
      QuestionProposal.confirm(proposal, proposal.proposals, actor: ctx.person, tenant: ctx.org)

    waiting = proposal!(ctx)

    {:ok, view, _html} = live(ctx.conn, @path)
    assert Enum.map(rows(pushed(view)), & &1["id"]) == [waiting.id]

    assert feedback(confirm(view, proposal))["kind"] == "error"
    assert status(proposal) == :confirmed
  end
end
