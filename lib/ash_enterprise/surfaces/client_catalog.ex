defmodule AshEnterprise.Surfaces.ClientCatalog do
  @moduledoc """
  Which A2UI component catalog a client is sent, from what it says it renders.

  A2UI v1.0 has the client list the catalogs it renders
  (`a2uiClientCapabilities.supportedCatalogIds`, sent in a message's
  metadata: on ACP, a request's `_meta`). `AshA2ui.Experience.catalog_for/1`
  reads that list; this module turns its answer into what a build needs:

    * the admin catalog, configured for this application, for a client that
      lists it (the web renderer, which sends no capabilities, gets it too);
    * the basic catalog for a client that lists only that one: the same
      surface with basic components, so nothing on it is a control the client
      cannot draw;
    * the declared fallback (`fallback/2`) for a client that lists neither, or
      sends a list that is empty, malformed or names only catalogs this server
      does not emit: no surface at all, and a sentence saying where the view is
      on the web. Such a client is never sent the basic catalog on the chance
      that it renders it.

  The build's catalog travels with the surface: pass the same options to
  every later build of it and to `AshA2ui.ActionHandler.handle/3` for its
  actions.
  """

  @capabilities "a2uiClientCapabilities"

  @doc """
  The client's A2UI capabilities from a request's params: under `_meta`, as
  ACP carries extension data. `nil` when it sent none.
  """
  @spec capabilities(map()) :: term()
  def capabilities(%{"_meta" => %{} = meta}), do: Map.get(meta, @capabilities)
  def capabilities(_params), do: nil

  @doc """
  `{:ok, build_opts}` (the `:catalog` to build with) for a client that sent
  `capabilities`, or `:fallback` when it renders no catalog this server emits.
  """
  @spec build_opts(term()) :: {:ok, keyword()} | :fallback
  def build_opts(capabilities) do
    case AshA2ui.Experience.catalog_for(capabilities) do
      {:ok, catalog} -> {:ok, [catalog: catalog]}
      {:error, :no_common_catalog} -> :fallback
    end
  end

  @doc """
  The declared fallback for a client that can render none of this server's
  catalogs: why nothing is shown, and where the view is on the web.
  """
  @spec fallback(String.t(), String.t()) :: map()
  def fallback(label, path) do
    %{
      "reason" => "unsupported_catalog",
      "message" =>
        "This client cannot show #{label}: it renders none of the component catalogs " <>
          "this server sends. Open it on the web at #{path}.",
      "path" => path
    }
  end
end
