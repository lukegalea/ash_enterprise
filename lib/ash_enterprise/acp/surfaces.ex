defmodule AshEnterprise.Acp.Surfaces do
  require Logger

  @moduledoc """
  `AshAcp.SurfaceProvider` for the dogfood ACP server (epic E3).

  Builds the locale-list **A2UI surface with `AshA2ui.Dynamic`** — the same
  validated pipeline declared `a2ui` DSL surfaces use (resource allowlist,
  field inference, authorized reads) — so ACP clients that render A2UI
  (amber_console) get a genuine A2UI list surface rather than transcript text.
  `ash_acp` carries the payload verbatim under `update._meta.a2ui`; neither the
  host hand-builds the wire shape nor the library re-defines it.

  Deliberately read-only and bounded (10 rows): surfaces are views, not
  exports.
  """

  @behaviour AshAcp.SurfaceProvider

  @spec_spec %{
    "resource" => "LanguageLocale",
    "title" => "Locales",
    "components" => [
      %{
        "kind" => "table",
        "name" => "locales",
        "fields" => ["code", "name"]
      }
    ]
  }

  @impl true
  def surface(session, _meta) do
    with {:ok, surface} <-
           AshA2ui.Dynamic.resolve(@spec_spec,
             allowlist: %{"LanguageLocale" => AshEnterprise.Reference.LanguageLocale}
           ) do
      AshA2ui.Dynamic.build_surface(surface,
        actor: session.actor,
        authorize?: true
      )
    else
      {:error, errors} ->
        Logger.warning("AshEnterprise.Acp.Surfaces: A2UI resolve failed: #{inspect(errors)}")

        nil
    end
  rescue
    error ->
      Logger.warning("AshEnterprise.Acp.Surfaces failed: #{Exception.message(error)}")
      nil
  end
end
