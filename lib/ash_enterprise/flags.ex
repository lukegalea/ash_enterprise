defmodule AshEnterprise.Flags do
  @moduledoc """
  Feature flags, tenant by tenant (ADR 0072).

    * `AshEnterprise.Flags.Catalogue`: the keys this build declares, and the ones the
      deployment killed with `FLAGS_OFF`.
    * `AshEnterprise.Flags.Flag`: one tenant's decision for one key: off, on, or on
      for named people, teams, business-unit subtrees and a percentage.
    * `AshEnterprise.Flags.Targeting`: whether a row is on for a person, pure.

  `AshEnterprise.Security.ActorContext` resolves a tenant's rows into the keys that
  are on for the person once per request (and before every LiveView event), so
  `enabled?/2` is a set lookup on the actor and never queries. Turning a flag off
  takes effect at the person's next request or event.

  Managed through the code interface below, as a person holding a grant on
  `Flag`, and from the shell with `mix ash_enterprise.flags`.
  """

  use Ash.Domain, otp_app: :ash_enterprise

  alias AshEnterprise.Flags.Catalogue
  alias AshEnterprise.Security.ActorContext

  resources do
    resource AshEnterprise.Flags.Flag do
      define :list_flags, action: :read
      define :get_flag, action: :read, get_by: [:key]
      define :set_flag, action: :set, args: [:key]
      define :turn_on_flag, action: :turn_on
      define :turn_off_flag, action: :turn_off
      define :target_flag, action: :target
    end
  end

  @doc """
  Whether the flag `key` is on for `actor`.

  Reads the `ActorContext` already attached to the actor (or the context itself) and
  never queries. False for a key the build does not declare (logged), for a key the
  deployment killed, and for an actor that carries no context: a flag check never
  builds one.
  """
  @spec enabled?(term(), String.t()) :: boolean()
  def enabled?(actor, key) do
    Catalogue.available?(key) and MapSet.member?(context(actor).flags, key)
  end

  defp context(%ActorContext{} = context), do: context
  defp context(%{__ash_enterprise_context__: %ActorContext{} = context}), do: context
  defp context(_actor), do: %ActorContext{}
end
