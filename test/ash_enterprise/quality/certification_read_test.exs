defmodule AshEnterprise.Quality.CertificationReadTest do
  @moduledoc """
  S1-97: a judged family's report reads the certification of the band table it bands
  through, which a person recorded in their own tenant, from the tenant whose replies are
  reported (`AshEnterprise.Quality.Gate.published_band_table/3`, through
  `BandTableCertification`'s `:for_definition`). Every way a certification can fail to
  apply reads as not certified, with its reason, and never as certified. Nothing is
  judged and no model is called.
  """

  use AshEnterprise.DataCase, async: false

  import AshEnterprise.SystemOne.Support, only: [person: 1]

  alias AshEnterprise.Platform.SystemActor
  alias AshEnterprise.Quality.{Gate, JudgedScores}
  alias AshEnterprise.SystemOne
  alias AshEnterprise.SystemOne.{BandTableCertification, Calibration}
  alias AshEnterprise.Test.Quality.BandTables
  alias AshJudgments.Calibration.FamilyConfig

  setup do
    %{definition: BandTables.published!(), tenant: Ash.UUID.generate()}
  end

  defp table(ctx, opts \\ []), do: Gate.published_band_table(:agent_reply_style, ctx.tenant, opts)

  # The certification as a judged score carries it, over the report the gate reads.
  defp judged(ctx, opts \\ []) do
    []
    |> Gate.family_report(:agent_reply_style, [tenant: ctx.tenant] ++ opts)
    |> JudgedScores.certification()
  end

  test "a certification made in the certifier's own tenant certifies the table for this one",
       ctx do
    certification = BandTables.certify!(ctx.definition)

    assert %{
             definition_id: id,
             content_hash: hash,
             certified_at: certified_at,
             certification: %{status: :certified, certifier_role: :judgment_certifier}
           } = table(ctx)

    assert id == ctx.definition.id
    assert hash == ctx.definition.content_hash
    assert certified_at == certification.certified_at
    refute certification.organization_id == ctx.tenant

    assert %{
             "status" => "certified",
             "band_table_version" => version,
             "certifier_role" => "judgment_certifier"
           } = judged(ctx)

    assert version == to_string(ctx.definition.version)
    refute Map.has_key?(judged(ctx), "reason")
  end

  describe "the instrument" do
    setup ctx do
      certifier_tenant = Ash.UUID.generate()

      {:ok, run, _outcome} =
        Calibration.record_run(
          [
            family: "agent_reply_style",
            question_hashes: ["sha256:" <> String.duplicate("1", 64)],
            model_version: "winnow:e4b",
            model_digest: "sha256:" <> String.duplicate("b", 64),
            runtime_version: "0.9.0",
            eval_set_hash: "sha256:" <> String.duplicate("c", 64),
            region: "ca",
            n: 2,
            n_per_class: %{},
            metrics: %{"accuracy" => "0.92"},
            ece: "0.03",
            brier: "0.08",
            conformal_thresholds: %{},
            source: :eval_set,
            created_by: "calibration-harness",
            observations_digest: "sha256:" <> String.duplicate("d", 64),
            pass_bar: %{"accuracy" => "0.9"},
            finished_at: DateTime.utc_now()
          ],
          actor: SystemActor.process(),
          tenant: certifier_tenant
        )

      Map.merge(ctx, %{run: run, certifier_tenant: certifier_tenant})
    end

    defp instrument(run, overrides \\ %{}) do
      Map.merge(
        %{
          model_version: run.model_version,
          model_digest: run.model_digest,
          runtime_version: run.runtime_version
        },
        overrides
      )
    end

    test "is the one the certified run measured, read from the certifier's tenant", ctx do
      BandTables.certify!(ctx.definition, %{calibration_run_id: ctx.run.id}, ctx.certifier_tenant)

      assert %{certification: %{status: :certified, instruments: [certified]}} =
               table = table(ctx)

      assert certified == %{
               model_digest: ctx.run.model_digest,
               runtime_version: ctx.run.runtime_version
             }

      assert Gate.certified?(table, :agent_reply_style, instrument: instrument(ctx.run))
    end

    test "another digest or runtime is not certified by it", ctx do
      BandTables.certify!(ctx.definition, %{calibration_run_id: ctx.run.id}, ctx.certifier_tenant)
      table = table(ctx)

      for overrides <- [
            %{model_digest: "sha256:" <> String.duplicate("f", 64)},
            %{runtime_version: "0.9.1"}
          ] do
        refute Gate.certified?(table, :agent_reply_style,
                 instrument: instrument(ctx.run, overrides)
               )
      end
    end

    test "a certification that names no run certifies no instrument", ctx do
      BandTables.certify!(ctx.definition)

      assert %{certification: %{status: :certified, instruments: []}} = table = table(ctx)
      refute Gate.certified?(table, :agent_reply_style, instrument: instrument(ctx.run))
    end
  end

  describe "is not certified" do
    test "when its certification was revoked, whatever else certifies it", ctx do
      BandTables.certify!(ctx.definition)
      BandTables.certify!(ctx.definition, %{status: :revoked})

      assert %{certified_at: nil, certification: %{status: :revoked}} = table(ctx)
      assert %{"status" => "not_certified", "reason" => "revoked"} = judged(ctx)

      assert Gate.family_report([], :agent_reply_style, tenant: ctx.tenant).verdict_reasons ==
               [:not_certified]
    end

    test "when what is certified is another version, or other content under this version",
         ctx do
      BandTables.certify!(ctx.definition, %{definition_version: "#{ctx.definition.version + 1}"})
      BandTables.certify!(ctx.definition, %{content_hash: "sha256:" <> String.duplicate("e", 64)})

      assert %{certified_at: nil, certification: %{status: :none}} = table(ctx)
      assert %{"status" => "not_certified", "reason" => "no_certification"} = judged(ctx)
    end

    test "when nothing certifies it", ctx do
      assert %{certified_at: nil, certification: %{status: :none}} = table(ctx)
      assert %{"status" => "not_certified", "reason" => "no_certification"} = judged(ctx)
    end

    test "when the certification is older than the family's max age", ctx do
      certification = BandTables.certify!(ctx.definition)
      max_age_days = FamilyConfig.fetch(:agent_reply_style).max_age_days
      later = DateTime.add(certification.certified_at, max_age_days + 1, :day)

      assert Gate.family_report([], :agent_reply_style, tenant: ctx.tenant, now: later).verdict_reasons ==
               [:band_table_too_old]

      assert %{"status" => "band_table_too_old"} = judged(ctx, now: later)
    end

    test "when the certification cannot be read", ctx do
      BandTables.certify!(ctx.definition)

      # The `ai` actor may not run the read: it is refused, and a refused read never
      # certifies (nor reads as "nothing certifies it").
      assert %{certified_at: nil, certification: %{status: :unreadable}} =
               table(ctx, actor: SystemActor.ai())

      assert %{"status" => "not_certified", "reason" => "certification_unreadable"} =
               judged(ctx, actor: SystemActor.ai())
    end
  end

  describe "the cross-tenant read" do
    test "shows whether and when, never who certified or on what", ctx do
      certification = BandTables.certify!(ctx.definition)
      reader = person(tenant: ctx.tenant)

      read = fn opts ->
        SystemOne.certifications_of_definition!(
          ctx.definition.key,
          to_string(ctx.definition.version),
          ctx.definition.content_hash,
          [actor: reader, tenant: ctx.tenant] ++ opts
        )
      end

      [row] = read.([])
      assert row.status == :certified
      assert row.certified_at == certification.certified_at

      # Selecting a withheld field does not show it.
      [selected] = read.(query: [select: [:certified_by, :calibration_run_id, :verification]])

      for row <- [row, selected],
          field <- [
            :certified_by,
            :calibration_run_id,
            :verification,
            :tenant_scope,
            :organization_id
          ] do
        assert %Ash.ForbiddenField{} = Map.fetch!(row, field), "#{field} is shown"
      end

      # The record's own read stays in the reader's tenant, where there is nothing.
      assert Ash.read!(BandTableCertification, actor: reader, tenant: ctx.tenant) == []
    end

    test "is run by a person or a system actor, never the ai actor", ctx do
      args = [ctx.definition.key, to_string(ctx.definition.version), ctx.definition.content_hash]
      BandTables.certify!(ctx.definition)

      for actor <- [person(tenant: ctx.tenant), SystemActor.oban()] do
        assert {:ok, [_row]} =
                 apply(
                   SystemOne,
                   :certifications_of_definition,
                   args ++ [[actor: actor, tenant: ctx.tenant]]
                 )
      end

      # Refused, it reads nothing; asked to say so, it is an error.
      assert {:ok, []} =
               apply(
                 SystemOne,
                 :certifications_of_definition,
                 args ++ [[actor: SystemActor.ai(), tenant: ctx.tenant]]
               )

      assert {:error, %Ash.Error.Forbidden{}} =
               apply(
                 SystemOne,
                 :certifications_of_definition,
                 args ++ [[actor: SystemActor.ai(), tenant: ctx.tenant, authorize_with: :error]]
               )
    end
  end
end
