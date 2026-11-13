defmodule AshEnterprise.Security.AuditedDeployment do
  @moduledoc """
  The audited deployment class: a deployment that holds real data under the SOC 2 controls
  says so with `DEPLOYMENT_CLASS=audited`, and `config/runtime.exs` refuses to boot it,
  naming every problem, unless:

    * it runs the production configuration (`MIX_ENV=prod`). The dev and test
      configurations mount the dev routes (`/admin`, the LiveDashboard, the mailbox),
      compile the showcase's fault points in, let event replay clear tables, and serve plain
      http; the production one forces https (`force_ssl` in `config/prod.exs`) and builds
      its URLs as https;
    * self-registration is off: `SELF_REGISTRATION` does not turn it on
      (`AshEnterprise.Accounts.Changes.RefuseSelfRegistration`), so accounts are
      provisioned by the operator;
    * the showcase's demo fault panel is off: `SHOWCASE_FAULT_CONTROLS` does not turn it on
      (`AshEnterprise.Showcase`).

  Unset, the class is not audited and nothing here applies: dev, test, CI and a demo
  deployment need no change. The class is deliberately not derived from `MIX_ENV`: a
  production build can be a demo, and an instance can run the dev configuration and still
  hold real data, which is exactly what the first check refuses once the class is declared.

  ## What it cannot check

  There is no multi-factor requirement and no way to switch the password door off: the
  password strategy is the only interactive sign-in this application has, and it asks for
  no second factor. An audited deployment therefore boots with password-only sign-in. That
  is a gap in the application, not a setting this guard could insist on.
  """

  @variable "DEPLOYMENT_CLASS"
  @on ~w(1 true yes)

  @doc "The class an environment map (`System.get_env/0`) declares: `:audited`, `nil`, or unknown."
  @spec class(%{String.t() => String.t()}) :: :audited | nil | {:unknown, String.t()}
  def class(env) do
    case env |> Map.get(@variable, "") |> String.trim() do
      "" -> nil
      "audited" -> :audited
      other -> {:unknown, other}
    end
  end

  @doc "Every reason `env` cannot boot under the `config_env` configuration. Empty when it can."
  @spec problems(%{String.t() => String.t()}, atom()) :: [String.t()]
  def problems(env, config_env) do
    case class(env) do
      nil ->
        []

      :audited ->
        configuration(config_env) ++ registration(env) ++ demo(env)

      {:unknown, other} ->
        ["#{@variable} must be audited or unset, got: #{inspect(other)}"]
    end
  end

  @doc "Raises naming every problem; `:ok` when there are none."
  @spec assert!(%{String.t() => String.t()}, atom()) :: :ok
  def assert!(env, config_env) do
    case problems(env, config_env) do
      [] ->
        :ok

      problems ->
        raise "this deployment is audited (#{@variable}=audited) and cannot boot:\n" <>
                Enum.map_join(problems, "\n", &("  - " <> &1))
    end
  end

  defp configuration(:prod), do: []

  defp configuration(config_env) do
    [
      "it runs the #{config_env} configuration, which mounts the dev routes and the " <>
        "showcase's fault points and serves plain http: run a MIX_ENV=prod build"
    ]
  end

  defp registration(env) do
    if on?(env, "SELF_REGISTRATION"),
      do: ["self-registration must be off: unset SELF_REGISTRATION"],
      else: []
  end

  defp demo(env) do
    if on?(env, "SHOWCASE_FAULT_CONTROLS"),
      do: ["the showcase's demo fault panel must be off: unset SHOWCASE_FAULT_CONTROLS"],
      else: []
  end

  defp on?(env, var), do: String.downcase(String.trim(Map.get(env, var, ""))) in @on
end
