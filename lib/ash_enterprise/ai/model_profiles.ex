defmodule AshEnterprise.AI.ModelProfiles do
  @moduledoc """
  `AshEnterprise.AI.ModelProfile`'s `list`: the in-zone generative profile, as
  configuration, the zone check (`AshEnterprise.Assistant.ZoneGate`) and the call
  record (`AshEnterprise.AI.ModelCall`, read as the person) say it stands.

  Nothing here calls a model or probes its host: readiness is only what was recorded.
  A profile nothing recorded vouches for reads `:unknown`, never `:ready`
  (`AshEnterprise.AI.ModelProfile`).
  """

  use Ash.Resource.ManualRead

  require Ash.Query

  alias AshEnterprise.AI.{ModelCall, ModelProfile, Models, SecretShape}
  alias AshEnterprise.Assistant.ZoneGate
  alias AshEnterprise.Platform.LocalTime

  # How long one answered call vouches for a profile.
  @fresh_s 24 * 60 * 60

  @impl true
  def read(_query, _data_layer_query, _opts, context) do
    opts =
      context
      |> Ash.Context.to_opts()
      |> Keyword.take([:actor, :tenant, :tracer])
      |> Keyword.put(:authorize?, true)

    {:ok, [in_zone(Models.resolve(Models.default_spec()), opts)]}
  end

  @doc """
  The in-zone profile's row for `target` (the model agent runs call now), its last call
  read with `opts`, at `now`.
  """
  @spec in_zone(Models.Target.t(), keyword(), DateTime.t()) :: ModelProfile.t()
  def in_zone(target, opts, now \\ DateTime.utc_now()) do
    configured? = target.profile == Models.in_zone_profile_name()

    {readiness, note, at} =
      cond do
        not configured? ->
          {:not_configured,
           "Not configured: S1_GEN_BASE_URL and S1_GEN_MODEL are not both set, so nothing " <>
             "runs on this profile. Nothing falls back to a hosted model.", nil}

        ZoneGate.check(target) != :ok ->
          {:not_ready,
           "Not in the canonical store's zone, so agent runs refuse it and no content " <>
             "reaches it.", nil}

        true ->
          from_record(last_call(opts), now)
      end

    struct!(ModelProfile, %{
      key: Models.in_zone_profile_name(),
      label: "In-zone generative",
      model: if(configured?, do: target.label),
      zone: if(configured?, do: target.zone),
      readiness: readiness,
      ready: readiness == :ready,
      readiness_note: note,
      last_call_at: at,
      permitted_use: [
        "Agent runs, the assistant's among them: the only profile an agent version may " <>
          "be published to run on.",
        "Interpretation and other AI actions in this application, when no other model " <>
          "is named."
      ],
      restrictions: restrictions()
    })
  end

  defp last_call(opts) do
    ModelCall
    |> Ash.Query.filter(profile == ^Models.in_zone_profile_name())
    |> Ash.Query.sort(created_on: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read(opts)
  end

  defp from_record({:ok, []}, _now) do
    {:unknown,
     "No call on this profile is recorded that you may read, so whether it answers is " <>
       "not known.", nil}
  end

  defp from_record({:ok, [%{outcome: :ok, created_on: at}]}, now) do
    if DateTime.diff(now, at, :second) <= @fresh_s do
      {:ready, "Its last recorded call, at #{LocalTime.stamp(at)}, answered.", at}
    else
      {:unknown,
       "Its last recorded call, at #{LocalTime.stamp(at)}, answered, but that is more " <>
         "than a day ago; whether it answers now is not known.", at}
    end
  end

  defp from_record({:ok, [%{outcome: outcome, created_on: at}]}, _now) do
    {:not_ready, "Its last recorded call, at #{LocalTime.stamp(at)}, #{outcome_text(outcome)}.",
     at}
  end

  defp from_record({:error, _error}, _now) do
    {:unknown,
     "The record of this profile's calls could not be read as you, so whether it " <>
       "answers is not known.", nil}
  end

  defp outcome_text(:refused), do: "was refused"
  defp outcome_text(_failed), do: "failed"

  defp restrictions do
    guard =
      if Models.require_in_zone?(),
        do:
          "REQUIRE_IN_ZONE_MODELS is on: every call to a model outside the zone is refused " <>
            "before anything is sent.",
        else:
          "REQUIRE_IN_ZONE_MODELS is off: a caller that names a hosted model reaches it, " <>
            "recorded as outside the zone. Agent runs still use only this profile."

    [
      "Runs inside the deployment's zone only. Its host and key come from the operator's " <>
        "configuration; a caller cannot send its calls anywhere else.",
      guard,
      "Every call is recorded by its structure (caller, model, outcome, tokens), never " <>
        "its prompt or output.",
      "Text shaped like a key, token or password is refused before any call. Accounts " <>
        "are linked on Accounts & syncs (#{SecretShape.connection_path()}), never pasted."
    ]
  end
end
