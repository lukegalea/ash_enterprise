defmodule AshEnterprise.SystemOne.Instrument do
  @moduledoc """
  The identity a judgment records for the instrument that answered it: the
  profile's model, the digest the runtime reports for that model and the
  runtime's version (`/api/version`). A person's verdict on a judgment feeds the
  calibration slot those three key, so a job that judges reads them once per run
  and judges nothing when it cannot (`AshEnterprise.Standards.StandingWorker`,
  `AshEnterprise.Quality.Evaluation`).
  """

  @doc """
  `{:ok, %{model_version:, model_digest:, runtime_version:}}` for the instrument
  profile named `profile` (`config :ash_judgments, profiles:`), or `{:error, reason}`.
  """
  @spec identity(atom()) :: {:ok, map()} | {:error, term()}
  def identity(profile) do
    with {:ok, profile} <- AshJudgments.Profile.fetch(profile),
         {:ok, digest} <- AshJudgments.Profile.Digest.fetch(profile),
         {:ok, transport} <- AshJudgments.Profile.req_llm_opts(profile),
         {:ok, version} <- runtime_version(Keyword.fetch!(transport, :base_url)) do
      {:ok, %{model_version: profile.model, model_digest: digest, runtime_version: version}}
    end
  end

  defp runtime_version(base_url) do
    case Req.get(base_url <> "/api/version", retry: false) do
      {:ok, %{status: 200, body: %{"version" => version}}} -> {:ok, "ollaya-" <> version}
      other -> {:error, {:runtime_version_unavailable, other}}
    end
  end
end
