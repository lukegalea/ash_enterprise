defmodule AshEnterprise.SystemOne.JudgmentTest do
  @moduledoc """
  The host side of the judgment ledger (AST-88): attribution, postures and
  policies on the real host resources.

  The package's own suite proves the record/replay contract on its test
  app; this one proves what only the host can prove — that a judgment
  recorded through the real judge→recorder path lands on the platform base
  as an AshEvents event attributed to its tenant and correlation group
  (AC-4), that erasure on the host is itself an attributed event, and that
  the post-AST-136 policy model holds: system machinery writes judgments,
  people write human verdicts, and the `ai` actor writes nothing (AC-5).
  """

  use AshEnterprise.DataCase, async: false

  import AshEnterprise.SystemOne.Support

  require Ash.Query

  alias AshEnterprise.Platform.Correlation
  alias AshEnterprise.Platform.SystemActor
  alias AshEnterprise.SystemOne.HumanVerdict
  alias AshEnterprise.SystemOne.Judgment
  alias AshJudgments.Ledger
  alias AshJudgments.Registry.Canonical

  setup do
    Correlation.start_new()

    # The profiles resolve `{:system, var}` references at call time; judge
    # tests exercise that resolution, and the fake model replaces the
    # transport, so the URL is never dialled.
    System.put_env("OLLAYA_BASE_URL", "http://127.0.0.1:11435")
    System.put_env("OLLAYA_API_KEY", "local-test-only")

    on_exit(fn ->
      System.delete_env("OLLAYA_BASE_URL")
      System.delete_env("OLLAYA_API_KEY")
    end)

    %{org: Ash.UUID.generate()}
  end

  # --- AC-4: attribution -------------------------------------------------------

  describe "audit attribution (AC-4)" do
    test "a :record create produces an AshEvents event attributed to tenant and correlation" do
      correlation_id = Ash.UUID.generate()
      org = Ash.UUID.generate()

      judgment =
        Correlation.with_correlation(correlation_id, fn ->
          record!(tenant: org)
        end)

      assert judgment.correlation_id == nil,
             "the caller's correlation id is an input, not a stamped one — nil when not passed"

      [event] = ledger_events(:record, judgment.id)

      assert event.resource == Judgment
      assert event.metadata["correlation_id"] == correlation_id
      # The chain trigger lifts the stamped tenant into the indexed column.
      assert event.organization_id == org
      # A system write: no user row behind it.
      assert event.user_id == nil
    end

    test "a judgment recorded through the real judge path carries tenant and correlation" do
      org = Ash.UUID.generate()
      correlation_id = Ash.UUID.generate()
      observation_id = Ash.UUID.generate()

      judgment =
        Correlation.with_correlation(correlation_id, fn ->
          judge!(tenant: org, observation_id: observation_id)
        end)

      assert judgment.correlation_id == correlation_id
      assert %DateTime{} = judgment.recorded_at

      [event] = ledger_events(:record, judgment.id)
      assert event.metadata["correlation_id"] == correlation_id
      assert event.organization_id == org
    end

    test "tombstoning is itself an attributed audit event (AC-6)" do
      org = Ash.UUID.generate()
      record_correlation = Ash.UUID.generate()
      erase_correlation = Ash.UUID.generate()

      judgment =
        Correlation.with_correlation(record_correlation, fn ->
          record!(tenant: org, state_ciphertext: "encrypted-state-bytes")
        end)

      Correlation.with_correlation(erase_correlation, fn ->
        tombstone!(judgment.id, tenant: org)
      end)

      [event] = ledger_events(:tombstone_state, judgment.id)
      assert event.resource == Judgment
      assert event.metadata["correlation_id"] == erase_correlation
      assert event.organization_id == org
    end
  end

  # --- the host tombstone ------------------------------------------------------

  describe "erasure on the host" do
    test "the payload goes, the digests stay, record_hash still verifies" do
      org = Ash.UUID.generate()

      judgment =
        record!(tenant: org, state_ciphertext: "encrypted-state-bytes")

      tombstoned = tombstone!(judgment.id, tenant: org)

      assert tombstoned.state_ciphertext == nil
      assert tombstoned.state_digest == judgment.state_digest
      assert tombstoned.record_hash == judgment.record_hash
    end
  end

  # --- AC-5: policies ----------------------------------------------------------

  describe "policy enforcement (AC-5)" do
    test "a person cannot hand-write an observation; a system actor can" do
      org = Ash.UUID.generate()
      person = person()

      assert {:error, forbidden} =
               Judgment
               |> Ash.Changeset.for_create(:record, observation_inputs(),
                 actor: person,
                 tenant: org
               )
               |> Ash.create()

      assert forbidden |> Exception.message() =~ ~r/forbidden/i

      # The system actor path — the recorder's own posture — succeeds.
      assert %Judgment{} = record!(tenant: org)
    end

    test "the ai actor can write nothing: not a judgment, not a verdict" do
      org = Ash.UUID.generate()
      judgment = record!(tenant: org)

      for {resource, action, inputs} <- [
            {Judgment, :record, observation_inputs()},
            {HumanVerdict, :record, verdict_inputs(judgment)}
          ] do
        assert {:error, forbidden} =
                 resource
                 |> Ash.Changeset.for_create(action, inputs,
                   actor: SystemActor.ai(),
                   tenant: org
                 )
                 |> Ash.create()

        assert forbidden |> Exception.message() =~ ~r/forbidden/i
      end
    end

    test "human verdicts are person writes: a system actor is refused" do
      org = Ash.UUID.generate()
      judgment = record!(tenant: org)

      assert {:error, forbidden} =
               HumanVerdict
               |> Ash.Changeset.for_create(:record, verdict_inputs(judgment),
                 actor: SystemActor.process(),
                 tenant: org
               )
               |> Ash.create()

      assert forbidden |> Exception.message() =~ ~r/forbidden/i

      person = person()

      assert {:ok, %HumanVerdict{} = verdict} =
               HumanVerdict
               |> Ash.Changeset.for_create(
                 :record,
                 verdict_inputs(judgment, reviewer: person.email),
                 actor: person,
                 tenant: org
               )
               |> Ash.create()

      # The reviewer input is recorded verbatim (the email is a CiString on
      # the user; the row stores the string).
      assert verdict.reviewer == to_string(person.email)
      assert %DateTime{} = verdict.recorded_at
    end

    test "erasure is an operator act: the recorder hand-off cannot tombstone" do
      org = Ash.UUID.generate()
      judgment = record!(tenant: org)

      # A changeset carrying the judge hand-off context (what the recorder
      # sets) gets the recorder bypass on a CREATE, but a tombstone update
      # from a person is still refused.
      person = person()

      assert {:error, forbidden} =
               judgment
               |> Ash.Changeset.for_update(:tombstone_state, %{}, actor: person, tenant: org)
               |> Ash.Changeset.set_context(%{judgments: %{"hand-off" => true}})
               |> Ash.update()

      assert forbidden |> Exception.message() =~ ~r/forbidden/i
    end
  end

  # --- the real judge→recorder path --------------------------------------------

  describe "the judge→recorder path" do
    test "a judged answer lands on the host ledger with the RFC §5 identity fields" do
      org = Ash.UUID.generate()
      observation_id = Ash.UUID.generate()

      judgment = judge!(tenant: org, observation_id: observation_id)

      assert judgment.id == observation_id, "the caller's observation id is the idempotency key"

      assert judgment.question_id ==
               "judgment:v0:AshEnterprise.SystemOne.TestSupport.Note#judgments/notes_follow_up"

      assert judgment.family == "system_one_notes"
      assert judgment.question_version == 1
      assert judgment.profile == "laya_cpu"
      assert judgment.answer_kind == :noul
      assert judgment.value == nil
      # Q9: a noul's distribution is derived from its single probability.
      # The derived side is the shortest round-trip of the actual double
      # (1 - 0.9 is not 0.1 in IEEE-754) — the §4.3 discipline, verbatim.
      assert judgment.probabilities == %{
               "true" => "0.9",
               "false" => "0.09999999999999998"
             }

      assert judgment.mode == :live
      assert judgment.region == "ca"
      assert judgment.model_spec_requested =~ "laya"
      # §9: endpoints and keys never enter a record — the model travels as
      # the spec that was requested, whatever the resolved profile carried.
      refute judgment.model_spec_requested =~ "127.0.0.1"
      refute inspect(judgment) =~ "local-test-only"
      assert judgment.state_digest == Canonical.digest(Canonical.encode(%{"text" => "synthetic"}))

      assert judgment.cache_key ==
               Ledger.cache_key(%{
                 model_version: judgment.model_version,
                 question_hash: judgment.question_hash,
                 state_digest: judgment.state_digest
               })

      assert judgment.record_hash =~ ~r/^sha256:[0-9a-f]{64}$/

      # Exactly one observation for the one call.
      assert [_] = ledger_events(:record, judgment.id)
    end

    test "a person can trigger a judged question; the machinery records it" do
      org = Ash.UUID.generate()

      # ADR 0039: evaluate actions run as the requesting actor. The row
      # itself is the machinery's write (the recorder hand-off), and it is
      # attributed by tenant and correlation, not by who asked.
      assert {:ok, %AshAi.Evaluate.Noul{}} =
               judge(tenant: org, observation_id: Ash.UUID.generate(), actor: person())

      assert [_] = ledger_rows()
    end

    test "record: :must fails the judge closed when the insert fails" do
      org = Ash.UUID.generate()
      observation_id = Ash.UUID.generate()

      assert {:ok, _} = judge(tenant: org, observation_id: observation_id)

      # The observation id is the caller's idempotency key (RFC §4.1): the
      # same id again is a conflict, the question's posture is :must, and
      # so no answer leaves the action a second time.
      assert {:error, error} = judge(tenant: org, observation_id: observation_id)
      assert Exception.message(error) =~ "already been taken"

      assert [_] = ledger_events(:record, observation_id)
    end
  end

  # --- boot validation against the host's zone config ---------------------------

  describe "boot validation" do
    test "the ledger boots against the host's region and zone config" do
      # Law 10: every row carries the stack's region, from host config.
      assert Ledger.region!() == :ca

      # The recorder must find THIS host's ledger, not a test double.
      assert Application.get_env(:ash_judgments, :ledger) == Judgment

      # Residency is this host's policy (ADR 0042), wired next to the profiles.
      assert Application.get_env(:ash_judgments, :residency_policy) ==
               AshEnterprise.Zones.ResidencyPolicy

      # Every configured profile is in-region, or a record would carry a
      # region its instrument never ran in.
      for profile <- AshJudgments.Profile.registry() do
        assert profile.region == :ca, "#{profile.name} must be in-region (:ca)"
      end
    end
  end
end
