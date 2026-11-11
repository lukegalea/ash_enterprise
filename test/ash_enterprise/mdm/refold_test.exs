defmodule AshEnterprise.Mdm.RefoldTest do
  @moduledoc """
  MDM-10: a person's name and email are the fold of their attribute
  statements. One fold, one governing policy, values a column held before
  there were statements kept, and a merge that moves no rows.
  """

  # Not async: `seed_platform_organization` writes the one platform org row.
  use AshEnterprise.DataCase, async: false

  import AshEnterprise.Mdm.TestSupport, only: [staged_candidate!: 4]

  alias AshEnterprise.Accounts.User
  alias AshEnterprise.Canonical.Person
  alias AshEnterprise.Mdm.{AttributeAssertion, AutoMerge, MatchRuleSet, Refold}
  alias AshEnterprise.Platform.Seeder
  alias AshEnterprise.Security
  alias AshEnterprise.Security.ActorContext

  require Ash.Query

  @plain_key "AshEnterprise.Canonical.Person"
  @people_key "AshEnterprise.Canonical.Person#people"
  @rules [%{"name" => "email_exact", "kind" => "exact", "fields" => ["email"], "weight" => 1.0}]
  @t1 ~U[2026-01-01 00:00:00.000000Z]
  @t2 ~U[2026-02-01 00:00:00.000000Z]

  setup do
    seeded =
      Seeder.seed_tenant(
        name: "Mdm Refold #{System.unique_integer([:positive])}",
        unique_name: "mdm-refold-#{System.unique_integer([:positive])}"
      )

    Seeder.seed_platform_organization()

    %{org: seeded.organization.id, admin: seeded.user, seeded: seeded}
  end

  describe "one fold" do
    test "a changed value is one statement and one refold that names it", %{
      org: org,
      admin: admin
    } do
      person = person!(org, admin, nil, unique_email())

      say!(org, person, %{"name" => "Ann"}, "crm", @t1)
      assert reload(org, person).name == "Ann"
      before = statements(org, person)

      [statement] = Refold.assert!(org, person.id, %{"name" => "Anne"}, origin("crm", @t2))
      result = Refold.refold!(org, person.id)

      assert length(statements(org, person)) == length(before) + 1
      assert result.statements["name"].id == statement.id
      assert result.golden.name == "Anne"
      assert reload(org, person).name == "Anne"
    end

    test "the same statement twice is one row and no refold", %{org: org, admin: admin} do
      email = unique_email()
      person = project!(org, admin, "Ann", email, "gmail", @t1)
      before = statements(org, person)
      updated_at = reload(org, person).updated_at

      project!(org, admin, "Ann", email, "gmail", @t1)

      assert length(statements(org, person)) == length(before)
      assert reload(org, person).updated_at == updated_at
    end

    test "a refold of an absorbed row folds its golden", %{org: org, admin: admin} do
      survivor = person!(org, admin, "Ann", nil)
      loser = person!(org, admin, nil, unique_email())
      merge!(org, loser, survivor)

      assert Refold.refold!(org, loser.id).golden.id == survivor.id
    end
  end

  describe "the replay" do
    test ":mdm_replay_golden writes no statements", %{org: org, admin: admin} do
      golden_id = Ash.UUID.generate()

      Person
      |> Ash.Changeset.for_create(
        :mdm_replay_golden,
        %{
          golden_id: golden_id,
          name: "Replayed",
          email: unique_email(),
          owner_id: admin.id,
          owning_business_unit_id: admin.owning_business_unit_id
        },
        tenant: org,
        authorize?: false
      )
      |> Ash.create!(tenant: org, authorize?: false)

      assert AttributeAssertion
             |> Ash.Query.filter(golden_id == ^golden_id)
             |> Ash.read!(tenant: org, authorize?: false) == []
    end
  end

  describe "held values" do
    test "a person's held value survives a later import", %{org: org, admin: admin} do
      email = unique_email()
      person = person!(org, admin, "Held Name", email)

      project!(org, admin, "Import Name", email, "gmail", DateTime.utc_now())

      assert reload(org, person).name == "Held Name"

      assert [held] =
               org
               |> statements(person)
               |> Enum.filter(&(&1.source == "pre_assertion" and &1.attribute == "name"))

      assert held.origin_kind == :import
      assert held.origin_ref == %{"held" => true}
      assert held.observed_at == person.inserted_at

      assert Enum.any?(
               statements(org, person),
               &(&1.source == "gmail" and &1.attribute == "name")
             )
    end

    test "a held email outranks an import dated years before the row", %{org: org, admin: admin} do
      held = unique_email()
      older = unique_email()
      person = person!(org, admin, "Held Name", held)

      Refold.refold!(org, person.id)
      say!(org, person, %{"email" => older}, "gmail", ~U[2020-01-01 00:00:00.000000Z])

      assert to_string(reload(org, person).email) == held
    end

    test "a steward's statement still replaces a held value", %{org: org, admin: admin} do
      held = unique_email()
      steward = unique_email()
      person = person!(org, admin, "Held Name", held)

      Refold.refold!(org, person.id)

      Refold.assert!(org, person.id, %{"email" => steward}, %{
        origin_kind: :human,
        source: "steward",
        origin_ref: %{"test" => true},
        observed_at: ~U[2020-01-01 00:00:00.000000Z]
      })

      Refold.refold!(org, person.id)

      assert to_string(reload(org, person).email) == steward
    end

    test "a held value is recorded once", %{org: org, admin: admin} do
      person = person!(org, admin, "Held Name", unique_email())

      Refold.refold!(org, person.id)
      count = length(statements(org, person))
      Refold.refold!(org, person.id)

      assert length(statements(org, person)) == count
    end

    test "a projector refresh does not overwrite another source's older value", %{
      org: org,
      admin: admin
    } do
      email = unique_email()
      person = project!(org, admin, "From Gmail", email, "gmail", @t1)

      project!(org, admin, "From Calendar", email, "calendar", @t2)

      assert reload(org, person).name == "From Gmail"
    end

    test "under most_recent the newer source does win", %{org: org, admin: admin} do
      active_rule_set!(org, @plain_key, %{"default" => "most_recent"})
      email = unique_email()
      person = project!(org, admin, "From Gmail", email, "gmail", @t1)

      project!(org, admin, "From Calendar", email, "calendar", @t2)

      assert reload(org, person).name == "From Calendar"
    end
  end

  describe "the governing policy" do
    test "the plain Person key decides", %{org: org} do
      plain = active_rule_set!(org, @plain_key, %{"default" => "most_recent"})
      active_rule_set!(org, @people_key, %{"default" => "most_complete"})

      assert %{rule_set: %{id: id}, policy: %{"default" => "most_recent"}} = Refold.governing(org)
      assert id == plain.id
    end

    test "without it, the people flow's rule set decides", %{org: org} do
      people = active_rule_set!(org, @people_key, %{"default" => "most_complete"})

      assert %{rule_set: %{id: id}, policy: %{"default" => "most_complete"}} =
               Refold.governing(org)

      assert id == people.id
    end

    test "with neither, non_null decides", %{org: org} do
      assert Refold.governing(org) == %{rule_set: nil, policy: %{"default" => "non_null"}}
    end
  end

  describe "merge and unmerge" do
    test "unmerge restores both sides and the merge moved no rows", %{org: org, admin: admin} do
      active_rule_set!(org, @plain_key, %{"default" => "most_recent"})
      email = unique_email()
      survivor = project!(org, admin, "Survivor", nil, "crm", @t1)
      loser = project!(org, admin, "Loser", email, "gmail", @t2)
      loser_before = statements(org, loser)

      loser = merge!(org, loser, survivor)

      assert statements(org, loser) |> Enum.map(& &1.id) |> Enum.sort() ==
               loser_before |> Enum.map(& &1.id) |> Enum.sort()

      merged_survivor = reload(org, survivor)
      assert merged_survivor.name == "Loser"
      assert to_string(merged_survivor.email) == email

      unmerged =
        loser
        |> Ash.Changeset.for_update(:mdm_unmerge, %{}, tenant: org, authorize?: false)
        |> Ash.update!(tenant: org, authorize?: false)

      restored_survivor = reload(org, survivor)
      assert restored_survivor.name == "Survivor"
      assert is_nil(restored_survivor.email)

      refute unmerged.merged
      assert unmerged.name == "Loser"
      assert to_string(unmerged.email) == email
    end

    test "source_rank works on a merge, and names the winning source", %{org: org, admin: admin} do
      active_rule_set!(org, @plain_key, %{
        "default" => "source_rank",
        "source_rank" => ["salesforce"]
      })

      survivor = project!(org, admin, "From HubSpot", unique_email(), "hubspot", @t1)
      loser = project!(org, admin, "From Salesforce", unique_email(), "salesforce", @t2)

      loser = merge!(org, loser, survivor)

      assert reload(org, survivor).name == "From Salesforce"

      assert %{
               "winner" => "loser",
               "strategy" => "source_rank",
               "source" => "salesforce",
               "assertion_id" => id
             } = loser.merge_provenance["winners"]["name"]

      assert Ash.get!(AttributeAssertion, id, tenant: org, authorize?: false).golden_id ==
               loser.id
    end

    test "a people-flow rule set using source_rank merges too", %{org: org, admin: admin} do
      active_rule_set!(org, @people_key, %{
        "default" => "source_rank",
        "source_rank" => ["salesforce"]
      })

      survivor = project!(org, admin, "From HubSpot", unique_email(), "hubspot", @t1)
      loser = project!(org, admin, "From Salesforce", unique_email(), "salesforce", @t2)

      merge!(org, loser, survivor)

      assert reload(org, survivor).name == "From Salesforce"
    end
  end

  describe "the staged-record path" do
    test "fold! honours the survivorship policy", %{org: org, admin: admin} do
      active_rule_set!(org, @plain_key, %{"default" => "most_recent"})
      email = unique_email()
      {_candidate, staged, golden} = staged_candidate!(org, admin, "Staged Name", email)
      Refold.refold!(org, golden.id)

      assert :ok = AutoMerge.fold!(staged, golden, org)

      assert reload(org, golden).name == "Staged Name"
    end

    test "under the default the golden's own value still stands", %{org: org, admin: admin} do
      email = unique_email()
      {_candidate, staged, golden} = staged_candidate!(org, admin, "Staged Name", email)
      name = golden.name
      Refold.refold!(org, golden.id)

      assert :ok = AutoMerge.fold!(staged, golden, org)

      assert reload(org, golden).name == name
    end
  end

  describe "who can read a statement" do
    test "only someone who can read the person", %{org: org, admin: admin, seeded: seeded} do
      person = person!(org, admin, "Ann", unique_email())
      Refold.refold!(org, person.id)
      colleague = colleague!(seeded)

      assert [_ | _] = read_as(admin, org)
      assert read_as(colleague, org) == []
    end
  end

  defp person!(org, admin, name, email) do
    Person
    |> Ash.Changeset.for_create(:upsert_from_source, %{
      name: name,
      email: email,
      owner_id: admin.id,
      owning_business_unit_id: admin.owning_business_unit_id
    })
    |> Ash.create!(tenant: org, authorize?: false)
  end

  # A projector's write: the name is a statement, so the upsert leaves it alone.
  defp project!(org, admin, name, email, source, observed_at) do
    Person
    |> Ash.Changeset.for_create(
      :upsert_from_source,
      %{
        name: name,
        email: email,
        statement_source: source,
        statement_observed_at: observed_at,
        owner_id: admin.id,
        owning_business_unit_id: admin.owning_business_unit_id
      },
      tenant: org,
      authorize?: false
    )
    |> Ash.create!(upsert?: true, upsert_identity: :unique_email, upsert_fields: [])
  end

  defp say!(org, person, values, source, observed_at) do
    :ok = Refold.assert_from_source!(org, person.id, values, source, observed_at)
  end

  defp origin(source, observed_at) do
    %{
      origin_kind: :import,
      source: source,
      origin_ref: %{"test" => true},
      observed_at: observed_at
    }
  end

  defp merge!(org, loser, survivor) do
    loser
    |> Ash.Changeset.for_update(:mdm_merge_into, %{survivor_id: survivor.id},
      tenant: org,
      authorize?: false
    )
    |> Ash.update!(tenant: org, authorize?: false)
  end

  defp reload(org, person), do: Ash.reload!(person, tenant: org, authorize?: false)

  defp statements(org, person) do
    AttributeAssertion
    |> Ash.Query.filter(golden_id == ^person.id)
    |> Ash.read!(tenant: org, authorize?: false)
  end

  defp read_as(user, org) do
    AttributeAssertion
    |> Ash.Query.for_read(:read, %{},
      actor: ActorContext.attach(user, ActorContext.build(user, tenant: org)),
      tenant: org
    )
    |> Ash.read!()
  end

  defp active_rule_set!(org, key, survivorship) do
    MatchRuleSet
    |> Ash.Changeset.for_create(
      :draft,
      %{golden_resource: key, rules: @rules, survivorship: survivorship},
      tenant: org,
      authorize?: false
    )
    |> Ash.create!(tenant: org, authorize?: false)
    |> Ash.Changeset.for_update(:activate, %{}, tenant: org, authorize?: false)
    |> Ash.update!(tenant: org, authorize?: false)
  end

  defp colleague!(seeded) do
    colleague =
      User
      |> Ash.Changeset.for_create(
        :register_with_password,
        %{
          email: unique_email(),
          password: "password1234",
          password_confirmation: "password1234"
        },
        authorize?: false
      )
      |> Ash.create!()
      |> Ash.Changeset.for_update(
        :assign_to_business_unit,
        %{owning_business_unit_id: seeded.business_unit.id},
        authorize?: false
      )
      |> Ash.update!()

    Security.UserRole
    |> Ash.Changeset.for_create(
      :assign,
      %{
        user_id: colleague.id,
        role_id: seeded.role.id,
        scoping_business_unit_id: seeded.business_unit.id
      },
      tenant: seeded.organization.id,
      authorize?: false
    )
    |> Ash.create!()

    colleague
  end

  defp unique_email, do: "p-#{System.unique_integer([:positive])}@refold.synthetic.test"
end
