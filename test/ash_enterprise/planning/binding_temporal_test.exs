defmodule AshEnterprise.Planning.BindingTemporalTest do
  @moduledoc """
  A run resolves its binding as of its knowledge cutoff, never as of now (ADR 0062): a
  binding changed after the cutoff resolves to the version valid at the cutoff, and a cutoff
  before the binding existed is refused when the run is prepared.
  """

  use AshEnterprise.DataCase, async: true

  import AshEnterprise.Test.DailyFixtures, only: [tenant!: 0, member!: 3]

  alias AshEnterprise.Planning
  alias AshEnterprise.Planning.Run
  alias AshEnterprise.Platform.SystemActor

  defp hex(char), do: String.duplicate(char, 64)

  defp selection(hash),
    do: [%{kind: "mzn", key: "week", version: "1", content_hash: hash}]

  setup do
    admin = tenant!()
    me = member!(admin, "Nobody special", [])
    aopts = [actor: admin.actor, tenant: admin.tenant]

    mv =
      Planning.draft_model_version!(
        %{
          key: "week-#{System.unique_integer([:positive])}",
          version: 1,
          model_sha256: hex("a"),
          checker_sha256: hex("b"),
          validator_module: "Tmp.Validator",
          validator_sha256: hex("c")
        },
        aopts
      )
      |> Planning.publish_model_version!(aopts)

    now = DateTime.utc_now()
    t0 = DateTime.add(now, -2 * 86_400, :second)
    t1 = DateTime.add(now, -1 * 86_400, :second)

    binding =
      Planning.bind_planning_model!(
        %{
          model_key: mv.key,
          purpose: "planning.week",
          selection: selection(hex("1")),
          backend_profile_hash: hex("d")
        },
        aopts ++ [as_of: t0]
      )

    rebound =
      Planning.rebind_planning_model!(
        binding,
        %{selection: selection(hex("2")), backend_profile_hash: hex("d")},
        aopts ++ [as_of: t1]
      )

    assert rebound.selection == [
             hd(selection(hex("2"))) |> Map.new(fn {k, v} -> {to_string(k), v} end)
           ]

    run =
      Planning.request_planning_run!(
        %{binding_id: binding.id, model_version_id: mv.id},
        actor: me.actor,
        tenant: me.tenant,
        authorize?: true
      )

    %{
      run: run,
      oban: [actor: SystemActor.oban(), tenant: admin.tenant],
      t0: t0,
      t1: t1,
      between: DateTime.add(t0, 43_200, :second)
    }
  end

  defp prepare(run, cutoff, oban) do
    Planning.prepare_planning_run(
      run,
      %{
        preparation_status: :prepared,
        snapshot_digest: hex("f"),
        knowledge_cutoff: cutoff,
        problem_payload: "{}"
      },
      oban
    )
  end

  test "a binding changed after the cutoff resolves to the version valid at the cutoff", ctx do
    assert {:ok, run} = prepare(ctx.run, ctx.between, ctx.oban)
    assert run.knowledge_cutoff == ctx.between

    assert {:ok, old} = Run.resolve_binding(run)
    assert [%{"content_hash" => old_hash}] = old.selection
    assert old_hash == hex("1")
  end

  test "a cutoff after the change resolves to the newer version", ctx do
    assert {:ok, run} = prepare(ctx.run, DateTime.add(ctx.t1, 60, :second), ctx.oban)
    assert {:ok, new} = Run.resolve_binding(run)
    assert [%{"content_hash" => hex}] = new.selection
    assert hex == hex("2")
  end

  test "a cutoff before the binding existed is refused", ctx do
    assert {:error, error} = prepare(ctx.run, DateTime.add(ctx.t0, -3600, :second), ctx.oban)
    assert Exception.message(error) =~ "as of the knowledge cutoff"
  end

  test "a future cutoff and a missing cutoff are refused", ctx do
    assert {:error, _} =
             prepare(ctx.run, DateTime.add(DateTime.utc_now(), 3600, :second), ctx.oban)

    assert {:error, _} = prepare(ctx.run, nil, ctx.oban)
  end

  test "an unprepared run has no binding to resolve", ctx do
    assert {:error, :not_prepared} = Run.resolve_binding(ctx.run)
  end
end
