defmodule AshEnterpriseWeb.SessionContext do
  @moduledoc """
  What the context band (`AshEnterpriseWeb.Layouts.context_band/1`) says about
  the person at the keyboard: the tenant they are working in, whom they act as,
  and, when they act on someone else's behalf, who is really there
  (`AshEnterprise.Security.Impersonation`).

  Built once per mount by `AshEnterpriseWeb.SurfaceDoor` into the page chrome,
  never in a render or a policy check.

    * `tenant`: `{:named, name}`; `:none` when the actor belongs to no tenant;
      `:unknown` when it has one this could not read. Never a blank that reads
      as "no tenant" when the read failed.
    * `identity`: the actor's email, or `nil` for an actor without one.
    * `impersonator`: `nil` when the actor acts as themselves; `{:named,
      email}` for the operator behind them; `:unknown` when an operator is
      recorded but could not be named. Impersonation is shown either way.
  """

  alias AshEnterprise.Accounts
  alias AshEnterprise.Security.{ActorContext, Impersonation}

  @type t :: %{
          tenant: {:named, String.t()} | :none | :unknown,
          identity: String.t() | nil,
          impersonator: {:named, String.t()} | :unknown | nil
        }

  @doc "The band's context for `actor`, or `nil` without one."
  @spec for_actor(term()) :: t() | nil
  def for_actor(nil), do: nil

  def for_actor(actor) do
    %{
      tenant: tenant(ActorContext.tenant(actor)),
      identity: identity(actor),
      impersonator: impersonator(Impersonation.impersonator_id(actor))
    }
  end

  # The name of the actor's own tenant, whose id comes from the actor's
  # precomputed context and never from input. A member with no grant on
  # Organization still knows where they are working, as
  # `AshEnterpriseWeb.Locale.organization_locale/1` reads its locale, so this
  # one read is not made as the actor; it answers the name and nothing else.
  defp tenant(nil), do: :none

  defp tenant(organization_id) do
    case Accounts.get_organization(organization_id,
           authorize?: false,
           query: [select: [:id, :name]]
         ) do
      {:ok, %{name: name}} when is_binary(name) and name != "" -> {:named, name}
      _unreadable -> :unknown
    end
  end

  defp identity(%{email: email}) when not is_nil(email), do: to_string(email)
  defp identity(_actor), do: nil

  # The operator is named from the id the impersonating actor carries, which
  # only the server sets (`Impersonation.acting_as/2`). The customer they act
  # as may not read the operator's record, and the band must still say who is
  # there, so this one read is not made as the actor; it answers the email and
  # nothing else.
  defp impersonator(nil), do: nil

  defp impersonator(operator_id) do
    case Accounts.get_user(operator_id, authorize?: false, query: [select: [:id, :email]]) do
      {:ok, %{email: email}} when not is_nil(email) -> {:named, to_string(email)}
      _unnamed -> :unknown
    end
  end
end
