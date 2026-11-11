defmodule AshEnterprise.Security.BreakGlassTest do
  @moduledoc """
  Impersonation is attribution, never reach (`AshEnterprise.Security.Impersonation`).
  A break-glass session is the record that says it was allowed: who acted,
  as whom, why, who approved it and until when. Without a live row there is no
  impersonating actor.

  A session is only as good as its refusals, so most of these are the ways a
  row must not be opened or must not be counted.
  """

  use AshEnterprise.DataCase, async: false

  import AshEnterprise.Test.DailyFixtures,
    only: [tenant!: 0, member!: 3, deactivate!: 1]

  require Ash.Query

  alias AshEnterprise.Audit.EventLog
  alias AshEnterprise.Platform.SystemActor
  alias AshEnterprise.Security.{BreakGlassSession, Impersonation}

  @grants [{BreakGlassSession, :create, :global}, {BreakGlassSession, :write, :global}]
  @approver_grants [{BreakGlassSession, :write, :global}]

  setup do
    admin = tenant!()
    operator = member!(admin, "Operator #{System.unique_integer([:positive])}", @grants)
    approver = member!(admin, "Approver #{System.unique_integer([:positive])}", @approver_grants)
    subject = member!(admin, "Subject #{System.unique_integer([:positive])}", [])
    %{admin: admin, operator: operator, approver: approver, subject: subject}
  end

  defp open(ctx, attrs \\ %{}) do
    BreakGlassSession
    |> Ash.Changeset.for_create(
      :open,
      Map.merge(
        %{
          subject_id: ctx.subject.user.id,
          approver_id: ctx.approver.user.id,
          reason: "Customer reported a failed import; ticket 4521",
          duration_minutes: 30
        },
        attrs
      ),
      actor: ctx.operator.actor
    )
    |> Ash.create()
  end

  defp open!(ctx, attrs \\ %{}) do
    {:ok, session} = open(ctx, attrs)
    session
  end

  defp approve(session, actor) do
    session
    |> Ash.Changeset.for_update(:approve, %{}, actor: actor)
    |> Ash.update()
  end

  # An opened session is not live until the named approver approves it.
  defp live!(ctx, attrs \\ %{}) do
    session = open!(ctx, attrs)
    {:ok, session} = approve(session, ctx.approver.actor)
    session
  end

  test "a session records operator, subject, reason, approver and expiry", ctx do
    session = open!(ctx)

    assert session.operator_id == ctx.operator.user.id
    assert session.subject_id == ctx.subject.user.id
    assert session.approver_id == ctx.approver.user.id
    assert session.reason =~ "failed import"
    assert DateTime.diff(session.expires_at, session.started_at, :minute) == 30
    assert session.lifecycle_status == :active
  end

  test "opening one writes an audit event", ctx do
    session = open!(ctx)

    events =
      EventLog |> Ash.Query.filter(record_id == ^session.id) |> Ash.read!(authorize?: false)

    assert Enum.any?(events, &(to_string(&1.action) == "open"))
  end

  describe "a row that must not be opened" do
    test "no reason, or a reason too short to mean anything", ctx do
      for reason <- [nil, "", "   ", "urgent"] do
        assert {:error, _} = open(ctx, %{reason: reason})
      end
    end

    test "no approver", ctx do
      assert {:error, _} = open(ctx, %{approver_id: nil})
    end

    test "the operator approving their own session", ctx do
      assert {:error, _} = open(ctx, %{approver_id: ctx.operator.user.id})
    end

    test "the person being impersonated approving it", ctx do
      assert {:error, _} = open(ctx, %{approver_id: ctx.subject.user.id})
    end

    test "an approver who is deactivated", ctx do
      deactivate!(ctx.approver)
      assert {:error, _} = open(ctx)
    end

    test "an approver or subject who does not exist", ctx do
      assert {:error, _} = open(ctx, %{approver_id: Ash.UUID.generate()})
      assert {:error, _} = open(ctx, %{subject_id: Ash.UUID.generate()})
    end

    test "impersonating yourself", ctx do
      assert {:error, _} = open(ctx, %{subject_id: ctx.operator.user.id})
    end

    test "no duration, a zero one, or one past the maximum", ctx do
      max = BreakGlassSession.max_minutes()

      for minutes <- [nil, 0, -5, max + 1] do
        assert {:error, _} = open(ctx, %{duration_minutes: minutes})
      end

      assert {:ok, _} = open(ctx, %{duration_minutes: max})
    end

    test "an operator who holds no grant to open one", ctx do
      stranger = member!(ctx.admin, "Nobody #{System.unique_integer([:positive])}", [])

      assert {:error, %Ash.Error.Forbidden{}} =
               BreakGlassSession
               |> Ash.Changeset.for_create(
                 :open,
                 %{
                   subject_id: ctx.subject.user.id,
                   approver_id: ctx.approver.user.id,
                   reason: "Customer reported a failed import",
                   duration_minutes: 10
                 },
                 actor: stranger.actor
               )
               |> Ash.create()
    end

    test "a system actor, because a session names a person", ctx do
      assert {:error, _} =
               BreakGlassSession
               |> Ash.Changeset.for_create(
                 :open,
                 %{
                   subject_id: ctx.subject.user.id,
                   approver_id: ctx.approver.user.id,
                   reason: "Customer reported a failed import",
                   duration_minutes: 10
                 },
                 actor: SystemActor.seed()
               )
               |> Ash.create()
    end
  end

  describe "approval" do
    test "an opened session is not live: the operator naming an approver is not approval", ctx do
      session = open!(ctx)
      assert is_nil(session.approved_at)

      assert {:error, :no_live_session} =
               Impersonation.break_glass(ctx.subject.user, ctx.operator.user)
    end

    test "the named approver approving makes it live and is audited", ctx do
      session = open!(ctx)
      assert {:ok, approved} = approve(session, ctx.approver.actor)
      assert %DateTime{} = approved.approved_at
      assert {:ok, _} = Impersonation.break_glass(ctx.subject.user, ctx.operator.user)

      events =
        EventLog |> Ash.Query.filter(record_id == ^session.id) |> Ash.read!(authorize?: false)

      assert Enum.any?(events, &(to_string(&1.action) == "approve"))
    end

    test "the operator cannot approve their own session", ctx do
      assert {:error, _} = approve(open!(ctx), ctx.operator.actor)

      assert {:error, :no_live_session} =
               Impersonation.break_glass(ctx.subject.user, ctx.operator.user)
    end

    test "the subject cannot approve, nor an active colleague who was not named", ctx do
      other = member!(ctx.admin, "Other #{System.unique_integer([:positive])}", @approver_grants)
      session = open!(ctx)

      assert {:error, _} = approve(session, ctx.subject.actor)
      assert {:error, _} = approve(session, other.actor)

      assert {:error, :no_live_session} =
               Impersonation.break_glass(ctx.subject.user, ctx.operator.user)
    end

    test "an operator acting as the named approver cannot approve their own session", ctx do
      session = open!(ctx)
      # The operator already holds a live session acting as the approver, so the actor is the
      # approver's struct with the operator in metadata.
      as_approver = Impersonation.acting_as(ctx.approver.actor, ctx.operator.user)
      assert Impersonation.impersonating?(as_approver)

      assert {:error, _} = approve(session, as_approver)

      assert {:error, :no_live_session} =
               Impersonation.break_glass(ctx.subject.user, ctx.operator.user)

      # Control: the approver themselves, not impersonated, still approves.
      assert {:ok, _} = approve(session, ctx.approver.actor)
    end

    test "an impersonating actor cannot open a session either", ctx do
      colleague = member!(ctx.admin, "Colleague #{System.unique_integer([:positive])}", @grants)
      as_colleague = Impersonation.acting_as(colleague.actor, ctx.operator.user)

      assert {:error, _} =
               BreakGlassSession
               |> Ash.Changeset.for_create(
                 :open,
                 %{
                   subject_id: ctx.subject.user.id,
                   approver_id: ctx.approver.user.id,
                   reason: "Customer reported a failed import; ticket 4521",
                   duration_minutes: 30
                 },
                 actor: as_colleague
               )
               |> Ash.create()
    end

    test "a system actor cannot approve", ctx do
      assert {:error, _} = approve(open!(ctx), SystemActor.seed())
    end

    test "an approver without a grant cannot approve", ctx do
      bare = member!(ctx.admin, "Bare #{System.unique_integer([:positive])}", [])
      session = open!(ctx, %{approver_id: bare.user.id})
      assert {:error, %Ash.Error.Forbidden{}} = approve(session, bare.actor)
    end

    test "approval is refused after expiry, once approved, and when the approver is deactivated",
         ctx do
      expired = open!(ctx)
      past = DateTime.add(DateTime.utc_now(), -1, :second)

      AshEnterprise.Repo.query!(
        "update break_glass_sessions set expires_at = $1 where id = $2",
        [past, Ecto.UUID.dump!(expired.id)]
      )

      expired = Ash.get!(BreakGlassSession, expired.id, authorize?: false)
      assert {:error, _} = approve(expired, ctx.approver.actor)

      session = open!(ctx)
      assert {:ok, approved} = approve(session, ctx.approver.actor)
      assert {:error, _} = approve(approved, ctx.approver.actor)

      pending = open!(ctx)
      deactivate!(ctx.approver)
      assert {:error, _} = approve(pending, ctx.approver.actor)
    end
  end

  describe "acting as the subject" do
    test "a live session yields an actor attributed to the operator", ctx do
      session = live!(ctx)

      assert {:ok, actor} = Impersonation.break_glass(ctx.subject.user, ctx.operator.user)
      assert actor.id == ctx.subject.user.id
      assert Impersonation.impersonator_id(actor) == ctx.operator.user.id
      assert actor.__metadata__.break_glass_session_id == session.id
    end

    test "no session means no impersonating actor", ctx do
      assert {:error, :no_live_session} =
               Impersonation.break_glass(ctx.subject.user, ctx.operator.user)
    end

    test "a session for someone else, or for another operator, does not count", ctx do
      live!(ctx)
      other = member!(ctx.admin, "Other #{System.unique_integer([:positive])}", [])

      assert {:error, :no_live_session} = Impersonation.break_glass(other.user, ctx.operator.user)
      assert {:error, :no_live_session} = Impersonation.break_glass(ctx.subject.user, other.user)
    end

    test "a session is gone at its expiry instant", ctx do
      session = live!(ctx)

      before = DateTime.add(session.expires_at, -1, :microsecond)

      assert {:ok, _} =
               Impersonation.break_glass(ctx.subject.user, ctx.operator.user, now: before)

      assert {:error, :no_live_session} =
               Impersonation.break_glass(ctx.subject.user, ctx.operator.user,
                 now: session.expires_at
               )
    end

    test "an ended session is gone", ctx do
      session = live!(ctx)

      session
      |> Ash.Changeset.for_update(:deactivate, %{}, actor: ctx.operator.actor)
      |> Ash.update!()

      assert {:error, :no_live_session} =
               Impersonation.break_glass(ctx.subject.user, ctx.operator.user)
    end

    test "a session does not survive its operator or its subject being deactivated", ctx do
      live!(ctx)
      deactivate!(ctx.operator)

      assert {:error, :no_live_session} =
               Impersonation.break_glass(ctx.subject.user, ctx.operator.user)
    end

    test "the subject deactivated while the session is open", ctx do
      live!(ctx)
      deactivate!(ctx.subject)

      assert {:error, :no_live_session} =
               Impersonation.break_glass(ctx.subject.user, ctx.operator.user)
    end

    test "malformed arguments are never a session", ctx do
      live!(ctx)
      assert {:error, :no_live_session} = Impersonation.break_glass(nil, ctx.operator.user)
      assert {:error, :no_live_session} = Impersonation.break_glass(ctx.subject.user, nil)
      assert {:error, :no_live_session} = Impersonation.break_glass(%{}, %{})
    end
  end
end
