defmodule AshEnterprise.Showcase do
  @moduledoc """
  The showcase: the governed-invocation programme's scenario as a running application a
  person can click through, built in slices over the demo data (`mix ash_enterprise.demo`).
  The first slice is the credentialing clinic (`AshEnterprise.Showcase.Credentialing`,
  toured at `/app/showcase/credentialing`).

  Two settings, under `config :ash_enterprise, AshEnterprise.Showcase`:

    * `fault_controls?` (default `false`) — the demo flag. It compiles the fault points
      in (`AshEnterprise.Faults`, which otherwise exist only under the test
      configuration) and shows the tour's fault panel, whose buttons arm them. It is
      read at compile time, so turning it on is a rebuild. `config/dev.exs` turns it on;
      production never does, and `config/prod.exs` must not.
    * `model_mode` (default `:recorded`) — how the showcase's agents get their model
      turns. `:recorded` replays fixture transcripts, so a tour is deterministic and needs
      no model; `:live` uses the in-zone generative profile and nothing else
      (`AshEnterprise.AI.Models`). The tour says which mode is on.
  """

  alias AshEnterprise.AI.Models
  alias AshEnterprise.Faults

  @modes [:recorded, :live]

  @doc """
  Whether the fault panel is on: the demo flag is set and the fault points were compiled
  in. Off in production, where neither holds.
  """
  @spec fault_controls?() :: boolean()
  def fault_controls?, do: config()[:fault_controls?] == true and Faults.enabled?()

  @doc "`:recorded` (the default) or `:live`."
  @spec model_mode() :: :recorded | :live
  def model_mode do
    case config()[:model_mode] do
      mode when mode in @modes ->
        mode

      nil ->
        :recorded

      other ->
        raise ArgumentError,
              "showcase model_mode must be one of #{inspect(@modes)}, got #{inspect(other)}"
    end
  end

  @doc """
  The model live mode would use: `{:ok, label}` for the in-zone generative profile, or
  `:not_configured` when the operator has declared none. Live mode never falls back to a
  hosted model.
  """
  @spec live_model() :: {:ok, String.t()} | :not_configured
  def live_model do
    case Models.resolve(Models.default_spec()) do
      %{residency: :in_zone, label: label} -> {:ok, label}
      _hosted -> :not_configured
    end
  end

  defp config, do: Application.get_env(:ash_enterprise, __MODULE__, [])
end
