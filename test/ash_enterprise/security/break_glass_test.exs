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

  setup do
    admin = tenant!()
    operator = member!(admin, "Operator #{System.unique_integer([:positive])}", @grants)
    approver = member!(admin, "Approver #{System.unique_integer([:positive])}", [])
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

  describe "acting as the subject" do
    test "a live session yields an actor attributed to the operator", ctx do
      session = open!(ctx)

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
      open!(ctx)
      other = member!(ctx.admin, "Other #{System.unique_integer([:positive])}", [])

      assert {:error, :no_live_session} = Impersonation.break_glass(other.user, ctx.operator.user)
      assert {:error, :no_live_session} = Impersonation.break_glass(ctx.subject.user, other.user)
    end

    test "a session is gone at its expiry instant", ctx do
      session = open!(ctx)

      before = DateTime.add(session.expires_at, -1, :microsecond)

      assert {:ok, _} =
               Impersonation.break_glass(ctx.subject.user, ctx.operator.user, now: before)

      assert {:error, :no_live_session} =
               Impersonation.break_glass(ctx.subject.user, ctx.operator.user,
                 now: session.expires_at
               )
    end

    test "an ended session is gone", ctx do
      session = open!(ctx)

      session
      |> Ash.Changeset.for_update(:deactivate, %{}, actor: ctx.operator.actor)
      |> Ash.update!()

      assert {:error, :no_live_session} =
               Impersonation.break_glass(ctx.subject.user, ctx.operator.user)
    end

    test "a session does not survive its operator or its subject being deactivated", ctx do
      open!(ctx)
      deactivate!(ctx.operator)

      assert {:error, :no_live_session} =
               Impersonation.break_glass(ctx.subject.user, ctx.operator.user)
    end

    test "the subject deactivated while the session is open", ctx do
      open!(ctx)
      deactivate!(ctx.subject)

      assert {:error, :no_live_session} =
               Impersonation.break_glass(ctx.subject.user, ctx.operator.user)
    end

    test "malformed arguments are never a session", ctx do
      open!(ctx)
      assert {:error, :no_live_session} = Impersonation.break_glass(nil, ctx.operator.user)
      assert {:error, :no_live_session} = Impersonation.break_glass(ctx.subject.user, nil)
      assert {:error, :no_live_session} = Impersonation.break_glass(%{}, %{})
    end
  end
end
