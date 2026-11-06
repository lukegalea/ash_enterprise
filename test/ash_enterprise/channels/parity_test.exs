defmodule AshEnterprise.Channels.ParityTest do
  @moduledoc """
  Channel parity (R2 HW-07, AGT-54): every act a person approves or executes
  (an effects declaration with `intent: :approve` or `:execute`) can be done on the web
  and over ACP, and neither needs a model to do it.

  Reached means:

    * **Web**: a registry surface's A2UI view offers it (a row, bulk, form or cell
      action), or a LiveView's event handler calls it (`@live_acts`, each checked
      against its source), or it is the governed act of a request door one of those
      offers (`AshEnterprise.Channels.door_target/2`).
    * **ACP**: a registry surface's ACP view offers it, or a verb of the prompt grammar
      routes to it (`AshEnterprise.Acp.Commands.verbs/0`), or it is the governed act of
      a request door one of those offers.

  An alias counts where the act it stands for counts (`@aliases`). What is not reached
  on both is either exempt, with the reason (`@exempt`), or a known gap with its
  follow-up (`@gaps`). Both lists are exact: an act nobody reaches that is in neither
  fails here, and so does an entry that no longer needs to be there.

  The registry surfaces are the same UI modules on both channels, so a surface action
  is a web action and an ACP action at once; no LiveView act here goes through a model
  (the agent console's role request does, which is why it is not one of them).
  """

  use ExUnit.Case, async: true

  alias AshEnterprise.Acp.Commands
  alias AshEnterprise.Agents.{Console, MorningBrief, ToolCall}
  alias AshEnterprise.Assistant.ReplyDraft
  alias AshEnterprise.Canonical.Task
  alias AshEnterprise.Channels
  alias AshEnterprise.Credentialing.Credential
  alias AshEnterprise.Execution.{AgentVersion, Intervention, ReleaseManifest, StartProcess}
  alias AshEnterprise.Security.UserRole
  alias AshEnterprise.Surfaces

  # Web acts no registry surface offers: a LiveView's own button, checked against its
  # source (the event it handles, and the call it makes).
  @live_acts [
    {MorningBrief, :compose_today, "lib/ash_enterprise_web/live/daily_live.ex",
     ~s|handle_event("compose_brief"|, "MorningBrief.compose_today"},
    {Intervention, :rerun, "lib/ash_enterprise_web/live/recovery_live.ex",
     ~s|handle_event("rerun"|, "Execution.rerun_invocation"},
    {Intervention, :cancel, "lib/ash_enterprise_web/live/recovery_live.ex",
     ~s|handle_event("cancel"|, "Execution.cancel_invocation"},
    {Intervention, :resolve, "lib/ash_enterprise_web/live/recovery_live.ex",
     ~s|handle_event("settle"|, "Execution.resolve_invocation"},
    {ReleaseManifest, :request_release,
     "lib/ash_enterprise_web/live/showcase_live/credentialing.ex",
     ~s|handle_event("request_release"|, "ReleaseTour.request"}
  ]

  # The prompt grammar's shorthands for an act a surface offers.
  @aliases %{
    {Console, :todo} => {Task, :capture},
    {Console, :done} => {Task, :complete_mine}
  }

  @exempt %{
    {UserRole, :assign} =>
      "the seed's and the directory sync's write; a person asks through " <>
        "`request_assignment`, which runs `assign_governed`",
    {ToolCall, :run_tool} =>
      "the agent runtime's dispatch of a model's tool call; a person's part is the " <>
        "confirmation it waits on, through approve and reject on both channels",
    {StartProcess, :start} =>
      "an agent's tool (`start_process`); a person confirms it through approve and reject",
    {ReplyDraft, :draft} =>
      "an agent's tool (`draft_reply`); a person confirms it through approve and reject",
    {Credential, :request_documents} =>
      "a step of the credential's case process, run by its service task"
  }

  # Acts a person should reach on both channels and does not yet, each with what is
  # missing. Closing one means deleting its line.
  @gaps %{
    {UserRole, :assign_governed} =>
      "web: only through the agent console, which needs its model to read the request",
    {AgentVersion, :apply_publish} =>
      "web: no surface or page offers `request_publish` yet (ACP: `publish <id>`)"
  }

  defp governed_acts do
    for domain <- Application.fetch_env!(:ash_enterprise, :ash_domains),
        resource <- Ash.Domain.Info.resources(domain),
        AshAgent.Effects in Spark.extensions(resource),
        effect <- AshAgent.Effects.Info.effects(resource),
        effect.intent in [:approve, :execute],
        uniq: true,
        do: {resource, effect.name}
  end

  defp view_acts(nil), do: []

  defp view_acts(ui) do
    view = AshA2ui.ResolvedView.resolve(ui, [])

    for part <- [view | view.tables],
        action <-
          List.wrap(Map.get(part, :row_actions)) ++
            List.wrap(Map.get(part, :bulk_actions)) ++
            [Map.get(part, :create_action), Map.get(part, :update_action)] ++
            [get_in(part, [Access.key(:editable, %{}), Access.key(:update_action)])],
        not is_nil(action),
        do: {Map.get(part, :resource) || view.resource, action}
  end

  defp with_doors(acts) do
    doors =
      for {resource, action} <- acts,
          target = Channels.door_target(resource, action),
          do: {resource, target}

    reached = MapSet.new(acts ++ doors)

    aliased =
      for {alias_act, original} <- @aliases, original in reached, do: alias_act

    MapSet.union(reached, MapSet.new(aliased))
  end

  defp web do
    surfaces = for surface <- Surfaces.all(), act <- view_acts(surface.ui), do: act
    live = for {resource, action, _file, _event, _call} <- @live_acts, do: {resource, action}
    with_doors(surfaces ++ live)
  end

  defp acp do
    surfaces =
      for surface <- Surfaces.all(), act <- view_acts(Surfaces.acp_ui(surface)), do: act

    verbs = for %{resource: resource, action: action} <- Commands.verbs(), do: {resource, action}
    with_doors(surfaces ++ verbs)
  end

  test "every act a person approves or executes is reached on the web and over ACP, or is accounted for" do
    web = web()
    acp = acp()
    acts = governed_acts()

    # Not vacuous: the registry of governed acts is read, and includes this lane's.
    assert length(acts) > 25
    assert {AshEnterprise.Bpmn.HumanTask, :request_info} in acts
    assert {Intervention, :rerun} in acts

    unreached =
      for act <- acts,
          not (act in web and act in acp),
          not Map.has_key?(@exempt, act),
          not Map.has_key?(@gaps, act),
          do: {act, web: act in web, acp: act in acp}

    assert unreached == [],
           "reach these on both channels, or exempt them with a reason: #{inspect(unreached)}"

    # Nothing is listed that does not need to be.
    settled = for act <- Map.keys(@gaps) ++ Map.keys(@exempt), act in web and act in acp, do: act
    assert settled == [], "reached on both channels now; delete the entry: #{inspect(settled)}"

    gone = for act <- Map.keys(@gaps) ++ Map.keys(@exempt), act not in acts, do: act
    assert gone == [], "no longer a governed act: #{inspect(gone)}"
  end

  test "the essential acts are on both channels: decisions, information, recovery, release" do
    web = web()
    acp = acp()

    essential = [
      {AshEnterprise.Bpmn.HumanTask, :approve},
      {AshEnterprise.Bpmn.HumanTask, :reject},
      {AshEnterprise.Bpmn.HumanTask, :request_info},
      {AshEnterprise.Bpmn.HumanTask, :answer},
      {AshEnterprise.Bpmn.HumanTask, :resolve},
      {Intervention, :cancel},
      {Intervention, :rerun},
      {Intervention, :resolve},
      {ReleaseManifest, :promote}
    ]

    for act <- essential do
      assert act in web, "#{inspect(act)} is not on the web"
      assert act in acp, "#{inspect(act)} is not over ACP"
    end

    # Publishing is over ACP; its web door is a known gap.
    assert {AgentVersion, :apply_publish} in acp
  end

  test "each LiveView act is the page's own button and calls the act, with no model in between" do
    for {_resource, _action, file, event, call} <- @live_acts do
      source = File.read!(file)
      assert source =~ event, "#{file} handles no #{event}"
      assert source =~ call, "#{file} does not call #{call}"
      refute source =~ "Interpreter.interpret", "#{file} reads its request through a model"
    end
  end

  test "every verb names a real action, and ACP offers no more than allow once and reject once" do
    for %{resource: resource, action: action, verb: verb} <- Commands.verbs() do
      assert Ash.Resource.Info.action(resource, action), "#{verb}: no #{inspect(action)}"
    end

    # A confirmation is one act, once: nothing is remembered as a standing grant.
    assert Application.fetch_env!(:ash_acp, :permission_options) == [:allow_once, :reject_once]
  end

  test "the vocabularies are the ones both channels answer with" do
    assert Channels.results() == [:applied, :pending, :declined, :forbidden, :invalid, :failed]

    assert Channels.blocked_reasons() ==
             [:forbidden, :approval_required, :policy_failed, :integration_unavailable]
  end
end
