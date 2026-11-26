defmodule AshEnterprise.Mdm.MatchRuleProposalTest do
  @moduledoc """
  S1-84: match-rule proposals from steward verdicts (ADR 0047: only a person
  adopts). A proposal holds a draft successor rule set learned by
  `AshMdm.Tuning`, replayed over the past verdicts through the tenant's band
  table before anyone can act on it; activating it is a person's act that goes
  through ash_mdm's own activation, and a proposal whose rule set has moved on
  cannot be activated.
  """

  use AshEnterprise.DataCase, async: false

  import AshEnterprise.Test.DailyFixtures, only: [tenant!: 0, member!: 3]

  alias AshEnterprise.Mdm
  alias AshEnterprise.Mdm.{Banding, MatchCandidate, MatchRuleProposal, MatchRuleSet}
  alias AshEnterprise.Platform.{Seeder, SystemActor}

  @golden "AshEnterprise.Canonical.Person"

  @rules [
    %{"name" => "email_exact", "kind" => "exact", "fields" => ["email"], "weight" => 1.0},
    %{
      "name" => "name_fuzzy",
      "kind" => "fuzzy",
      "field" => "name",
      "algorithm" => "jaro",
      "weight" => 1.0
    }
  ]

  setup do
    AshEnterprise.Process.Resolver.forget_platform_tenant()
    on_exit(&AshEnterprise.Process.Resolver.forget_platform_tenant/0)

    Banding.publish_seed_bands!(Seeder.seed_platform_organization().id)

    admin = tenant!()
    %{admin: admin, base: active_rule_set!(admin)}
  end

  defp active_rule_set!(admin) do
    MatchRuleSet
    |> Ash.Changeset.for_create(
      :draft,
      %{golden_resource: @golden, rules: @rules, survivorship: %{"default" => "non_null"}},
      tenant: admin.tenant,
      authorize?: false
    )
    |> Ash.create!()
    |> Ash.Changeset.for_update(:activate, %{}, tenant: admin.tenant, actor: admin.actor)
    |> Ash.update!()
  end

  # Decided pairs, as a steward's confirm or reject leaves them. Seeded: the
  # verdict machinery (merges, ledger rows) is its own tests' subject.
  defp decided!(admin, spec) do
    for {status, email, name, count} <- spec, _ <- 1..count do
      Ash.Seed.seed!(
        MatchCandidate,
        %{
          organization_id: admin.tenant,
          staged_record_id: Ash.UUID.generate(),
          golden_resource: @golden,
          golden_id: Ash.UUID.generate(),
          score: Decimal.new("0.7"),
          band: :review,
          status: status,
          explanation: %{
            "email_exact" => %{"w" => "1.0", "c" => email},
            "name_fuzzy" => %{"w" => "1.0", "c" => name}
          }
        },
        tenant: admin.tenant
      )
    end
  end

  # The confirms always agree on the email and half on the name; the rejects
  # never on the email and mostly on the name. One pair was scored by rules
  # this rule set does not have.
  defp history!(admin) do
    decided!(admin, [
      {:confirmed, "1", "1", 6},
      {:confirmed, "1", "0.5", 6},
      {:rejected, "0", "1", 8},
      {:rejected, "0", "0", 4}
    ])

    Ash.Seed.seed!(
      MatchCandidate,
      %{
        organization_id: admin.tenant,
        staged_record_id: Ash.UUID.generate(),
        golden_resource: @golden,
        golden_id: Ash.UUID.generate(),
        score: Decimal.new("0.9"),
        status: :confirmed,
        explanation: %{"rules" => [%{"rule" => "email_exact", "score" => "1.0"}]}
      },
      tenant: admin.tenant
    )
  end

  defp propose!(admin) do
    Mdm.propose_match_rules!(@golden, actor: SystemActor.proposer(), tenant: admin.tenant)
  end

  defp rule_set(id, admin),
    do: Ash.get!(MatchRuleSet, id, tenant: admin.tenant, authorize?: false)

  defp reload(proposal, admin),
    do: Ash.get!(MatchRuleProposal, proposal.id, tenant: admin.tenant, authorize?: false)

  describe "propose" do
    test "replays the steward verdicts under both versions, with exact counts", %{
      admin: admin,
      base: base
    } do
      history!(admin)
      proposal = propose!(admin)

      assert proposal.status == :proposed
      assert proposal.base_rule_set_id == base.id

      assert Map.take(
               proposal.replay,
               ~w(verdicts replayed skipped changed toward_admit toward_omit flips)
             ) ==
               %{
                 "verdicts" => 25,
                 "replayed" => 24,
                 "skipped" => 1,
                 "changed" => 14,
                 "toward_admit" => 6,
                 "toward_omit" => 8,
                 "flips" => 0
               }

      assert proposal.replay["before"] == %{
               "admit" => 6,
               "review" => 14,
               "omit" => 4,
               "agree" => 10,
               "disagree" => 0,
               "precision" => "1.0000",
               "recall" => "0.5000"
             }

      assert proposal.replay["after"]["recall"] == "1.0000"
      assert length(proposal.changed_pairs) == 14
      assert proposal.flips == 0

      assert Enum.map(proposal.tuning, &{&1["rule"], &1["status"], &1["weight_after"]}) == [
               {"email_exact", "proposed", 4.6439},
               {"name_fuzzy", "floored", 0.01}
             ]

      # The proposed rules are a draft successor, and nothing changes matching yet.
      draft = rule_set(proposal.rule_set_id, admin)
      assert {draft.status, draft.version, draft.root_id} == {:draft, 2, base.root_id || base.id}
      assert Enum.map(draft.rules, & &1["weight"]) == [4.6439, 0.01]
      assert rule_set(base.id, admin).status == :active

      # The replay banded through the table the tenant bands with, and recorded no evaluation.
      assert {:ok, table} = Banding.definition(admin.tenant)
      assert proposal.band_table_id == table.id

      loaded =
        Ash.load!(proposal, [:flagged, :replay_summary], tenant: admin.tenant, authorize?: false)

      refute loaded.flagged

      assert loaded.replay_summary =~
               "24 of 25 steward verdicts replayed (1 scored by other rules)"

      assert loaded.replay_summary =~ "14 would change band: 6 toward admit, 8 toward omit"
    end

    test "flags a proposal that would undo a steward-confirmed match", %{admin: admin} do
      history!(admin)
      # Two confirms the email disagrees on: a steward matched them on the name.
      flipped = decided!(admin, [{:confirmed, "0", "1", 2}])

      proposal = propose!(admin)

      assert {proposal.flips, proposal.replay["changed"]} == {2, 16}

      assert proposal.changed_pairs
             |> Enum.filter(& &1["flip"])
             |> Enum.map(&{&1["candidate_id"], &1["verdict"], &1["before"], &1["after"]})
             |> Enum.sort() ==
               flipped |> Enum.map(&{&1.id, "match", "review", "omit"}) |> Enum.sort()

      assert Ash.load!(proposal, :flagged, tenant: admin.tenant, authorize?: false).flagged
    end

    test "is refused when no rule earned a new weight", %{admin: admin} do
      decided!(admin, [{:confirmed, "1", "1", 3}, {:rejected, "0", "0", 3}])

      assert {:error, %Ash.Error.Invalid{} = error} =
               Mdm.propose_match_rules(@golden,
                 actor: SystemActor.proposer(),
                 tenant: admin.tenant
               )

      assert Exception.message(error) =~ "no rule earned a new weight"
      assert Ash.read!(MatchRuleProposal, tenant: admin.tenant, authorize?: false) == []
    end
  end

  describe "activate" do
    test "a person activates it, which versions the rule set", %{admin: admin, base: base} do
      history!(admin)
      proposal = propose!(admin)

      activated =
        Mdm.activate_match_rule_proposal!(proposal, actor: admin.actor, tenant: admin.tenant)

      assert activated.status == :activated
      assert rule_set(proposal.rule_set_id, admin).status == :active
      assert rule_set(base.id, admin).status == :retired
    end

    test "a non-person actor cannot activate it", %{admin: admin, base: base} do
      history!(admin)
      proposal = propose!(admin)

      for actor <- [SystemActor.system(), SystemActor.proposer(), SystemActor.ai()] do
        assert {:error, %Ash.Error.Forbidden{}} =
                 Mdm.activate_match_rule_proposal(proposal, actor: actor, tenant: admin.tenant)
      end

      assert reload(proposal, admin).status == :proposed
      assert rule_set(proposal.rule_set_id, admin).status == :draft
      assert rule_set(base.id, admin).status == :active
    end

    test "a person without the grant cannot activate it", %{admin: admin} do
      history!(admin)
      proposal = propose!(admin)
      reader = member!(admin, "Proposal reader", [{MatchRuleProposal, :read, :global}])

      assert {:error, %Ash.Error.Forbidden{}} =
               Mdm.activate_match_rule_proposal(proposal,
                 actor: reader.actor,
                 tenant: admin.tenant
               )

      assert rule_set(proposal.rule_set_id, admin).status == :draft
    end

    test "a stale proposal cannot be activated", %{admin: admin, base: base} do
      history!(admin)
      first = propose!(admin)
      second = propose!(admin)

      Mdm.activate_match_rule_proposal!(first, actor: admin.actor, tenant: admin.tenant)

      assert {:error, %Ash.Error.Invalid{} = error} =
               Mdm.activate_match_rule_proposal(second, actor: admin.actor, tenant: admin.tenant)

      assert Exception.message(error) =~ "no longer active"
      assert reload(second, admin).status == :proposed
      assert rule_set(second.rule_set_id, admin).status == :draft
      assert rule_set(first.rule_set_id, admin).status == :active
      assert rule_set(base.id, admin).status == :retired
    end

    test "a person rejects it and the active rules stay", %{admin: admin, base: base} do
      history!(admin)
      proposal = propose!(admin)

      rejected =
        Mdm.reject_match_rule_proposal!(proposal, actor: admin.actor, tenant: admin.tenant)

      assert rejected.status == :rejected
      assert rule_set(base.id, admin).status == :active

      assert {:error, %Ash.Error.Invalid{}} =
               Mdm.activate_match_rule_proposal(rejected,
                 actor: admin.actor,
                 tenant: admin.tenant
               )
    end
  end
end
