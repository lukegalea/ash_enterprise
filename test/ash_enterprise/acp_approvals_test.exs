defmodule AshEnterprise.Acp.ApprovalsTest do
  @moduledoc """
  The approval binding rule (epic E3, ADR 0015 seam): a permission resolution
  approves exactly the pending request it was issued for, in the session that
  requested it. A foreign session's ref — or an unknown one — can never
  approve anything, even with `allow_once`.
  """

  use AshEnterprise.DataCase, async: false

  alias AshEnterprise.Acp
  alias AshEnterprise.Acp.{Approvals, Session, SessionStore}

  setup do
    Acp.ensure_tables!()
    :ok
  end

  defp session(id) do
    {:ok, s} = SessionStore.create(%{"actor" => %{"id" => id}})
    s
  end

  # A write: writes always pend (dogfood §5), whatever the actor's grants.
  defp action_spec do
    %{resource: AshEnterprise.Reference.LanguageLocale, action: :create, label: "Create locale"}
  end

  test "the owning session's allow_once approves the pending ref" do
    session = session("op-1")
    {:pending, ref} = Approvals.request(session, action_spec(), %{})

    outcome = %{"outcome" => "selected", "optionId" => "allow_once"}
    assert {:approved, _} = Approvals.resolve(ref, outcome, session)
  end

  test "a foreign session's ref is denied even with allow_once" do
    owner = session("op-owner")
    foreign = session("op-foreign")

    {:pending, ref} = Approvals.request(owner, action_spec(), %{})

    outcome = %{"outcome" => "selected", "optionId" => "allow_once"}
    assert {:denied} = Approvals.resolve(ref, outcome, foreign)

    # and the request stays pending for its real owner
    assert {:approved, _} = Approvals.resolve(ref, outcome, owner)
  end

  test "an unknown ref is denied" do
    session = session("op-2")

    outcome = %{"outcome" => "selected", "optionId" => "allow_once"}
    assert {:denied} = Approvals.resolve(Ash.UUID.generate(), outcome, session)
  end

  test "reject_once denies without consuming the ref's approval" do
    session = session("op-3")
    {:pending, ref} = Approvals.request(session, action_spec(), %{})

    assert {:denied} =
             Approvals.resolve(
               ref,
               %{"outcome" => "selected", "optionId" => "reject_once"},
               session
             )

    # resolve is one-shot: a second resolution on the consumed ref is denied
    assert {:denied} =
             Approvals.resolve(
               ref,
               %{"outcome" => "selected", "optionId" => "allow_once"},
               session
             )
  end

  test "an authorized read auto-approves without a pending record" do
    session = session("op-read")

    spec = %{
      resource: AshEnterprise.Accounts.BusinessUnit,
      action: :read,
      label: "List business units"
    }

    assert {:approved, _} = Approvals.request(session, spec, %{})
  end

  test "sessions persist through the store (create stores, load restores)" do
    session = session("op-4")
    {:ok, loaded} = SessionStore.load(session.session_id)
    assert loaded.session_id == session.session_id

    SessionStore.append_message(loaded, :user, "hello")
    {:ok, reloaded} = SessionStore.load(session.session_id)
    assert reloaded.transcript == [{:user, "hello"}]
  end

  test "Session struct keeps its own module file" do
    assert %Session{} = struct(Session)
  end
end
