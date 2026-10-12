defmodule AshEnterprise.Acp.Surfaces do
  require Logger

  @moduledoc """
  `AshAcp.SurfaceProvider` for the dogfood ACP server.

  Closes each turn with the A2UI surface its prompt routed to
  (`AshEnterprise.Acp.Commands`): the same declared UI module the web page
  serves, built by `AshA2ui.Info.build_surface/2` for the session's actor —
  authorized reads, never a bypass, never hand-built JSON. `ash_acp` carries
  the messages verbatim under `update._meta.a2ui`.

  `list business units` keeps its agent-composed (`AshA2ui.Dynamic`) table.
  A surface that fails to build is logged and omitted: the transcript text
  still answers the prompt.
  """

  @behaviour AshAcp.SurfaceProvider

  alias AshEnterprise.Acp.SessionStore

  @business_units %{
    "resource" => "BusinessUnit",
    "title" => "Business units",
    "components" => [
      %{
        "kind" => "table",
        "name" => "business_units",
        "fields" => ["name"]
      }
    ]
  }

  @impl true
  def surface(session, _meta) do
    session.session_id
    |> SessionStore.surface_for()
    |> build(session.actor)
  rescue
    error ->
      Logger.warning("AshEnterprise.Acp.Surfaces failed: #{Exception.message(error)}")
      nil
  end

  defp build(nil, _actor), do: nil

  defp build(:business_units, actor) do
    case AshA2ui.Dynamic.resolve(@business_units,
           allowlist: %{"BusinessUnit" => AshEnterprise.Accounts.BusinessUnit}
         ) do
      {:ok, surface} ->
        AshA2ui.Dynamic.build_surface(surface,
          actor: actor,
          authorize?: true,
          tenant: AshEnterprise.Acp.tenant_of(actor)
        )

      {:error, errors} ->
        Logger.warning("AshEnterprise.Acp.Surfaces: A2UI resolve failed: #{inspect(errors)}")
        nil
    end
  end

  defp build({ui, opts}, actor) do
    opts =
      [actor: actor, tenant: AshEnterprise.Acp.tenant_of(actor)]
      |> put_present(:query_state, opts[:query_state])

    AshA2ui.Info.build_surface(ui, opts)
  end

  defp put_present(opts, _key, nil), do: opts
  defp put_present(opts, key, value), do: Keyword.put(opts, key, value)
end
