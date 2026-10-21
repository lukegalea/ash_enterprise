defmodule AshEnterprise.SystemOne.DecisionWire do
  @moduledoc """
  The in-zone transport for registry judge calls: the `req_llm` module a
  judge context names (`judgments: %{req_llm: #{inspect(__MODULE__)}}`).

  A generated `judge_<name>` action resolves the question's profile into an
  inline model spec, but upstream `evaluate` sends no transport options with
  it, so the `:typesafe` provider would fall back to its hosted default
  endpoint and fail for want of a key. This module supplies what the spec
  cannot carry: the profile's own `base_url`, `api_key` and
  `receive_timeout` (`AshJudgments.Profile.req_llm_opts/1`), resolved at call
  time from `config/runtime.exs`. The call then goes through
  `AshJudgments.Wire.ModelCapture`, so the runtime-reported model still
  lands on the recorded observation.

  The profile is found by the model id the spec names. Routes are keyed by
  model (`:model_routes`), so every profile serving one model shares its
  transport. A model no configured profile serves is refused, never sent
  anywhere.
  """

  alias AshJudgments.Profile

  @doc "`ReqLLM.evaluate/4` with the serving profile's transport options."
  def evaluate(model, state, questions, opts) do
    with {:ok, transport} <- transport(model) do
      AshJudgments.Wire.ModelCapture.evaluate(
        model,
        state,
        questions,
        Keyword.merge(opts, transport)
      )
    end
  end

  @doc "The transport options for the profile serving `model`."
  @spec transport(term()) :: {:ok, keyword()} | {:error, {:no_profile_for_model, term()}}
  def transport(model) do
    id = model_id(model)

    Profile.registry()
    |> Enum.find(&(&1.model == id and not is_nil(&1.base_url)))
    |> case do
      nil -> {:error, {:no_profile_for_model, id}}
      profile -> Profile.req_llm_opts(profile)
    end
  end

  defp model_id(%{provider_model_id: id}) when is_binary(id), do: id
  defp model_id(%{id: id}) when is_binary(id), do: id
  defp model_id(spec) when is_binary(spec), do: spec |> String.split(":", parts: 2) |> List.last()
  defp model_id(other), do: other
end
