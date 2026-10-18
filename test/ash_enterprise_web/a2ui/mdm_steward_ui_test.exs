defmodule AshEnterpriseWeb.A2ui.MdmStewardUITest do
  @moduledoc """
  The steward queue (`MdmStewardUI`) driven through ash_a2ui's own handler,
  as the people who click it: the queue and its staged-vs-golden diff read
  under the reader's policies, the three verdicts, bulk reject (and only
  reject), and the refusals — a person without the update grant cannot
  confirm or bulk-reject, a person without a read grant sees nothing, and a
  candidate whose golden the reader may not read is neither listed nor
  confirmable.
  """

  use AshEnterprise.DataCase, async: false

  import AshEnterprise.Mdm.TestSupport
  import AshEnterprise.Test.DailyFixtures, only: [tenant!: 0, member!: 3]

  require Ash.Query

  alias AshEnterprise.Acp.ExtMethods
  alias AshEnterprise.Mdm.{MatchCandidate, StagedRecord}
  alias AshEnterpriseWeb.A2ui.MdmStewardUI

  setup do
    %{admin: tenant!()}
  end

  defp candidate!(%{tenant: tenant, user: user}, name) do
    email = "#{String.downcase(String.replace(name, " ", "."))}@example.test"
    {candidate, _staged, _golden} = staged_candidate!(tenant, user, name, email)
    candidate
  end

  # A review candidate whose golden `owner` owns (Person is owner-only, so
  # owning it is how a steward who is not the admin may read it).
  defp candidate_owned_by!(%{tenant: tenant, user: user}, owner, name) do
    email = "#{String.downcase(String.replace(name, " ", "."))}@example.test"
    {_candidate, staged, _golden} = staged_candidate!(tenant, user, name, email)

    golden =
      AshEnterprise.Canonical.Person
      |> Ash.Changeset.for_create(:upsert_from_source, %{
        name: name <> " Theirs",
        email: nil,
        owner_id: owner.user.id,
        owning_business_unit_id: owner.user.owning_business_unit_id
      })
      |> Ash.create!(tenant: tenant, authorize?: false)

    MatchCandidate
    |> Ash.Changeset.for_create(:create, %{
      staged_record_id: staged.id,
      golden_resource: "AshEnterprise.Canonical.Person",
      golden_id: golden.id,
      score: Decimal.new("0.72"),
      explanation: %{"rules" => [%{"rule" => "email_exact", "score" => "1.0"}]}
    })
    |> Ash.create!(tenant: tenant, authorize?: false)
    |> Ash.Changeset.for_update(:update, %{band: :review}, tenant: tenant, authorize?: false)
    |> Ash.update!(tenant: tenant, authorize?: false)
  end

  defp reload(candidate, tenant),
    do: Ash.get!(MatchCandidate, candidate.id, tenant: tenant, authorize?: false)

  defp rows(person) do
    %{"updateDataModel" => %{"value" => value}} =
      AshA2ui.Info.build_data_model(MdmStewardUI, actor: person.actor, tenant: person.tenant)

    value["records"]
  end

  defp detail(person, candidate) do
    state =
      AshA2ui.Info.context_state_for(MdmStewardUI, %{"candidate" => candidate.id},
        actor: person.actor,
        tenant: person.tenant
      )

    %{"updateDataModel" => %{"value" => value}} =
      AshA2ui.Info.build_data_model(MdmStewardUI,
        actor: person.actor,
        tenant: person.tenant,
        context_state: state
      )

    get_in(value, ["detail", "candidate"])
  end

  defp invoke(person, action, candidate) do
    AshA2ui.ActionHandler.handle(
      MdmStewardUI,
      %{
        "name" => "invoke",
        "context" => %{"action" => action, "recordId" => candidate.id, "component" => "table"}
      },
      actor: person.actor,
      tenant: person.tenant
    )
  end

  defp bulk(person, action, candidates) do
    AshA2ui.ActionHandler.handle(
      MdmStewardUI,
      %{
        "name" => "bulk_invoke",
        "context" => %{
          "action" => action,
          "component" => "table",
          "records" => Enum.map(candidates, &%{"id" => &1.id, "_selected" => true})
        }
      },
      actor: person.actor,
      tenant: person.tenant
    )
  end

  # A steward who may read the queue, the staged rows and the goldens they
  # own (Person is owner-only), but holds no update grant on the candidates.
  defp reader!(admin) do
    member!(admin, "Queue reader", [
      {MatchCandidate, :read, :global},
      {StagedRecord, :read, :global},
      {AshEnterprise.Canonical.Person, :read, :basic}
    ])
  end

  describe "the queue" do
    test "lists the pending review candidates, oldest first, with their diff", %{admin: admin} do
      first = candidate!(admin, "Ann Dup")
      second = candidate!(admin, "Bob Dup")

      assert [%{"id" => id1} = row, %{"id" => id2}] = rows(admin)
      assert {id1, id2} == {first.id, second.id}
      assert row["staged_label"] == "Ann Dup"
      assert row["golden_label"] == "Ann Dup Existing"
      assert %{"surface" => "mdm_golden"} = row["_links"]["golden_label"]

      detail = detail(admin, first)
      assert detail["staged_name"] == "Ann Dup"
      assert detail["golden_name"] == "Ann Dup Existing"
      # The golden keeps its own name; it has no email, so the staged one wins.
      assert detail["name_survivor"] == "golden"
      assert detail["staged_email"] == "ann.dup@example.test"
      assert detail["email_survivor"] == "staged"
      assert detail["explanation_text"] == "email_exact: 1.0"
    end

    test "explains the matcher's own per-rule shape", %{admin: admin} do
      {_candidate, staged, _golden} =
        staged_candidate!(admin.tenant, admin.user, "Ann Dup", "ann.dup@example.test")

      # What `AshEnterprise.Mdm.BatchWorker` records: rule => contribution, weight.
      candidate =
        MatchCandidate
        |> Ash.Changeset.for_create(:create, %{
          staged_record_id: staged.id,
          golden_resource: "AshEnterprise.Canonical.Person",
          golden_id: Ash.UUID.generate(),
          score: Decimal.new("0.83"),
          explanation: %{
            "name_fuzzy" => %{"c" => "0.67", "w" => "0.5"},
            "email_exact" => %{"c" => "1", "w" => "1.0"}
          }
        })
        |> Ash.create!(tenant: admin.tenant, authorize?: false)

      assert [%{explanation_text: text}] =
               MatchCandidate
               |> Ash.Query.filter(id == ^candidate.id)
               |> Ash.Query.load(:explanation_text)
               |> Ash.read!(tenant: admin.tenant, authorize?: false)

      assert text == "email_exact: 1 (weight 1.0)\nname_fuzzy: 0.67 (weight 0.5)"
    end

    test "a decided candidate leaves the queue", %{admin: admin} do
      candidate = candidate!(admin, "Ann Dup")
      assert {:ok, _messages} = invoke(admin, "confirm", candidate)

      assert rows(admin) == []
    end

    # ADR 0017's existence rule: candidates are generated as a system actor,
    # so listing one whose golden the reader may not read would tell them
    # that golden exists.
    test "lists no candidate whose golden the reader may not read", %{admin: admin} do
      candidate!(admin, "Ann Dup")
      reader = reader!(admin)
      theirs = candidate_owned_by!(admin, reader, "Bob Dup")

      # Both candidates and their staged rows are readable; only Bob's golden
      # is theirs, Ann's is the admin's owner-only Person.
      assert [%{"id" => id, "golden_label" => "Bob Dup Theirs"}] = rows(reader)
      assert id == theirs.id
      assert length(rows(admin)) == 2
    end

    test "the diff shows what the reader may read, nothing more", %{admin: admin} do
      candidate = candidate!(admin, "Ann Dup")
      reader = reader!(admin)

      # Opened by id, the golden's side of the diff stays empty.
      detail = detail(reader, candidate)
      assert detail["staged_name"] == "Ann Dup"
      assert detail["golden_name"] in [nil, ""]
      assert detail["golden_email"] in [nil, ""]
      # An unreadable golden is not a golden with no values: no survivorship
      # claim is made about it.
      assert detail["name_survivor"] in [nil, ""]
      assert detail["email_survivor"] in [nil, ""]
    end

    test "a person without a read grant sees no candidate", %{admin: admin} do
      candidate!(admin, "Ann Dup")
      stranger = member!(admin, "No grants", [])

      assert rows(stranger) == []
    end
  end

  describe "the verdicts" do
    test "Confirm match merges, recording the update's verdict", %{admin: admin} do
      candidate = candidate!(admin, "Ann Dup")

      assert {:ok, _messages} = invoke(admin, "confirm", candidate)

      decided = reload(candidate, admin.tenant)
      assert decided.status == :confirmed
      assert to_string(decided.human_verdict_ref["verdict"]) == "confirm"
    end

    test "Reject match keeps the staged record separate", %{admin: admin} do
      candidate = candidate!(admin, "Ann Dup")

      assert {:ok, _messages} = invoke(admin, "reject", candidate)

      decided = reload(candidate, admin.tenant)
      assert decided.status == :rejected
      assert to_string(decided.human_verdict_ref["verdict"]) == "reject"
    end

    test "Mark unsure records the verdict and keeps the candidate open", %{admin: admin} do
      candidate = candidate!(admin, "Ann Dup")

      assert {:ok, _messages} = invoke(admin, "escalate", candidate)

      decided = reload(candidate, admin.tenant)
      assert decided.status == :pending
      assert to_string(decided.human_verdict_ref["verdict"]) == "unsure"
      assert [%{"id" => id}] = rows(admin)
      assert id == candidate.id
    end

    test "a decided candidate cannot be decided again", %{admin: admin} do
      candidate = candidate!(admin, "Ann Dup")
      assert {:ok, _messages} = invoke(admin, "confirm", candidate)

      assert {:error, _messages} = invoke(admin, "reject", candidate)
      assert reload(candidate, admin.tenant).status == :confirmed
    end

    test "a person without the update grant cannot confirm", %{admin: admin} do
      reader = reader!(admin)
      candidate = candidate_owned_by!(admin, reader, "Ann Dup")

      assert {:error, messages} = invoke(reader, "confirm", candidate)

      # A 0.9.1 surface reports the refusal as the typed `/ui/feedback`
      # error, which ACP classifies as a refusal.
      assert ExtMethods.failure_kind(messages) == :forbidden
      assert reload(candidate, admin.tenant).status == :pending
    end

    test "nobody confirms a merge into a golden they may not read", %{admin: admin} do
      candidate = candidate!(admin, "Ann Dup")

      # Every grant on the candidate, none on the golden (owner-only Person).
      steward =
        member!(admin, "Steward without goldens", [
          {MatchCandidate, :read, :global},
          {MatchCandidate, :write, :global},
          {StagedRecord, :read, :global}
        ])

      # Not in their queue, so the surface refuses it outright…
      assert {:error, _messages} = invoke(steward, "confirm", candidate)

      # …and the update itself refuses it by id.
      assert {:error, %Ash.Error.Forbidden{}} =
               candidate
               |> Ash.Changeset.for_update(:confirm, %{},
                 actor: steward.actor,
                 tenant: steward.tenant
               )
               |> Ash.update()

      assert reload(candidate, admin.tenant).status == :pending
      assert reload(candidate, admin.tenant).human_verdict_ref == nil
    end
  end

  describe "bulk" do
    test "Reject match runs over a selection", %{admin: admin} do
      candidates = [candidate!(admin, "Ann Dup"), candidate!(admin, "Bob Dup")]

      assert {:ok, _messages} = bulk(admin, "reject", candidates)

      assert Enum.map(candidates, &reload(&1, admin.tenant).status) == [:rejected, :rejected]
    end

    test "is offered for reject only: no bulk confirm, no bulk unsure", %{admin: admin} do
      candidates = [candidate!(admin, "Ann Dup"), candidate!(admin, "Bob Dup")]

      for action <- ["confirm", "escalate"] do
        assert {:error, _messages} = bulk(admin, action, candidates)
      end

      assert Enum.map(candidates, &reload(&1, admin.tenant).status) == [:pending, :pending]
      assert Enum.all?(candidates, &(reload(&1, admin.tenant).human_verdict_ref == nil))
    end

    test "a person without the update grant cannot bulk-reject", %{admin: admin} do
      candidates = [candidate!(admin, "Ann Dup"), candidate!(admin, "Bob Dup")]
      reader = reader!(admin)

      assert {:error, _messages} = bulk(reader, "reject", candidates)
      assert Enum.map(candidates, &reload(&1, admin.tenant).status) == [:pending, :pending]
    end

    test "ids the reader cannot read are refused, never acted on", %{admin: admin} do
      candidate = candidate!(admin, "Ann Dup")
      stranger = member!(admin, "No grants", [])

      assert {:error, _messages} = bulk(stranger, "reject", [candidate])
      assert reload(candidate, admin.tenant).status == :pending
    end
  end

  test "the buttons are the verdicts themselves, labelled; nothing is self-service" do
    # No wrapper actions: ash_a2ui labels the real updates.
    assert AshEnterprise.Security.Checks.SelfService.actions(MatchCandidate) == []

    labels = Map.new(AshA2ui.Info.action_settings(MdmStewardUI), &{&1.name, &1.label})

    assert %{confirm: "Confirm match", reject: "Reject match", escalate: "Mark unsure"} =
             Map.take(labels, [:confirm, :reject, :escalate])

    for wrapper <- [:confirm_match, :reject_match, :mark_unsure] do
      assert Ash.Resource.Info.action(MatchCandidate, wrapper) == nil
    end
  end
end
