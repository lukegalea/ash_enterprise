defmodule AshEnterprise.Mdm.SecondOpinionWorker do
  @moduledoc """
  The job that asks the model's second opinion on one review-banded pair
  (S1-83, `AshEnterprise.Mdm.SecondOpinion`), under the `oban` system actor.

  `AshEnterprise.Mdm.Changes.AskSecondOpinion` enqueues it when the matcher
  bands a pair review, and only while the second opinion is enabled. It
  carries the candidate's id and tenant, never the candidate: it reads the
  pair again when it runs, and asks nothing for a pair that is no longer
  pending in review or was already asked.

  The instrument identity (model, the digest the runtime reports for it,
  the runtime's version) is read from the `:winnow_gpu` profile when the job
  runs, the in-zone decision route: the pairs are personal data, so the
  question is never sent to a sub-processor. A job that cannot read it asks
  nothing and fails, so it retries, instead of recording an answer with no
  provenance. `config :ash_enterprise, AshEnterprise.Mdm.SecondOpinion,
  instrument: ...` (a map, or a zero-arity function returning `{:ok, map}`)
  replaces the lookup, and `ask_opts:` adds options to `SecondOpinion.ask/2`.
  """

  use Oban.Worker,
    queue: :system_one,
    max_attempts: 3,
    unique: [period: :infinity, keys: [:candidate_id], states: :incomplete]

  alias AshEnterprise.Mdm.{MatchCandidate, SecondOpinion}
  alias AshEnterprise.Platform.SystemActor
  alias AshEnterprise.SystemOne.Instrument

  @profile :winnow_gpu

  @doc "The job for one candidate: its id and tenant, string-keyed."
  @spec new_for(MatchCandidate.t()) :: Oban.Job.changeset()
  def new_for(%MatchCandidate{id: id, organization_id: tenant}),
    do: new(%{"candidate_id" => id, "tenant" => tenant})

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"candidate_id" => id, "tenant" => tenant}}) do
    case Ash.get(MatchCandidate, id, tenant: tenant, actor: SystemActor.oban(), error?: false) do
      {:ok, %MatchCandidate{band: :review, status: :pending, second_opinion: nil} = candidate} ->
        ask(candidate, tenant)

      {:ok, _decided_asked_or_gone} ->
        {:ok, :skipped}

      {:error, error} ->
        {:error, error}
    end
  end

  defp ask(candidate, tenant) do
    config = Application.get_env(:ash_enterprise, SecondOpinion, [])

    with {:ok, instrument} <- instrument(config[:instrument]),
         {:ok, %{reading: reading, acted: acted}} <-
           SecondOpinion.ask(
             candidate,
             [tenant: tenant, instrument: instrument, actor: SystemActor.oban()] ++
               Keyword.get(config, :ask_opts, [])
           ) do
      {:ok, %{reading: reading, acted: acted}}
    end
  end

  defp instrument(nil), do: Instrument.identity(@profile)
  defp instrument(fun) when is_function(fun, 0), do: fun.()
  defp instrument(%{} = instrument), do: {:ok, instrument}
end
