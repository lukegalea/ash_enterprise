defmodule AshBrowserTests.A2uiManifest do
  @moduledoc """
  The per-surface manifest the generator consumes for A2UI row actions: tables,
  presets, row actions, `visible_when` and `prompt_fields`, built by `ash_a2ui` from
  `AshA2ui.Info`.

  `ash_a2ui` does not ship this yet (`Stub` below is the placeholder until it does);
  this behaviour is the shape to build toward. `README.md` lists what is needed from
  it. `Static` serves a manifest written by hand, for tests and for hosts that want
  row-action coverage before the upstream manifest exists.
  """

  @type prompt_field :: %{
          required(:name) => String.t(),
          required(:label) => String.t(),
          optional(:type) => atom(),
          optional(:required) => boolean(),
          optional(:options) => [String.t()]
        }

  @type row_action :: %{
          required(:id) => String.t(),
          required(:label) => String.t(),
          required(:ash_action) => atom(),
          optional(:resource) => module() | String.t(),
          optional(:table) => String.t(),
          optional(:visible_when) => term(),
          optional(:prompt_fields) => [prompt_field()],
          optional(:confirm_label) => String.t() | nil
        }

  @type t :: %{
          required(:surface_id) => String.t(),
          required(:row_actions) => [row_action()],
          optional(:tables) => [map()]
        }

  @doc "The manifest for one surface, or `nil` when the surface has no A2UI content."
  @callback manifest(surface_id :: String.t()) :: t() | nil

  defmodule Stub do
    @moduledoc """
    The placeholder until `ash_a2ui` ships a manifest: every surface answers `nil`,
    so A2UI row actions contribute no obligations and no tests.
    """
    @behaviour AshBrowserTests.A2uiManifest

    @impl true
    def manifest(_surface_id), do: nil
  end

  defmodule Static do
    @moduledoc """
    A manifest from a map of surface id to manifest.

        use AshBrowserTests.A2uiManifest.Static, manifests: %{"orders" => %{...}}
    """

    defmacro __using__(opts) do
      quote do
        @behaviour AshBrowserTests.A2uiManifest
        @manifests unquote(opts[:manifests])

        @impl true
        def manifest(surface_id), do: Map.get(@manifests, surface_id)
      end
    end
  end
end
