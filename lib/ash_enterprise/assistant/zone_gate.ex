defmodule AshEnterprise.Assistant.ZoneGate do
  @moduledoc """
  Whether the assistant's read tools may hand content to the model that
  asked for it (ADR 0042's flow rule, for this one flow).

  Everything those tools return — event titles, mail, Slack, names — is
  canonical content held in the canonical store's zone. It may flow to a
  model target `T` only if `T` is in-zone and `T.zone` is the store's zone
  (`AshEnterprise.Canonical.Projections.ZoneAdmission.zone/0`).

  The tools answer an agent run (`AshEnterprise.Assistant.Agent`): a run's
  step hands its tools the run in the action context (`ash_agent.run_id`),
  and the model that reads the result is the one every run step calls
  (`AshEnterprise.Execution.AgentRuntime.target/0`), so that is the target
  checked. A caller with no run in its context — an MCP client, a hosted
  agent, a test that forgot — is refused.

  This sits beside the guard in `AshEnterprise.AI.Models`, not instead of
  it: the guard stops a *call* to a model outside the zone when
  `REQUIRE_IN_ZONE_MODELS` is on; this stops *content* reaching one whatever
  that flag says. Pure: reads configuration and the context, never the
  database.
  """

  alias AshEnterprise.AI.Models.Target
  alias AshEnterprise.Canonical.Projections.ZoneAdmission
  alias AshEnterprise.Execution.AgentRuntime

  @doc """
  `:ok` when `target` may receive canonical content, else `{:error,
  reason}` with `reason` one of `:no_model_target`, `:outside_zone` or
  `:zone_mismatch`.
  """
  @spec check(term()) :: :ok | {:error, atom()}
  def check(%Target{residency: :in_zone, zone: zone}) do
    if zone == ZoneAdmission.zone(), do: :ok, else: {:error, :zone_mismatch}
  end

  def check(%Target{}), do: {:error, :outside_zone}
  def check(_other), do: {:error, :no_model_target}

  @doc "The check for a tool called with `context`: a run's, against the run's model."
  @spec check_context(map() | nil) :: :ok | {:error, atom()}
  def check_context(%{ash_agent: %{run_id: run_id}}) when is_binary(run_id),
    do: check(AgentRuntime.target())

  def check_context(_context), do: check(nil)

  @doc "A sentence for a refusal: what the model reads instead of content."
  @spec refusal(atom()) :: String.t()
  def refusal(:no_model_target),
    do: "Refused: these tools answer only an agent run on the in-zone model (ADR 0042)."

  def refusal(:outside_zone),
    do: "Refused: the model asking is outside the zone, so no content is returned (ADR 0042)."

  def refusal(:zone_mismatch),
    do:
      "Refused: the model asking is not in the canonical store's zone, so no content " <>
        "is returned (ADR 0042)."
end
