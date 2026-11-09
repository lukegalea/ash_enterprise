defmodule AshBrowserTests.Surface do
  @moduledoc """
  One thing a host serves that a person can open: a page behind a path and an actor,
  and the actions that can be taken on it.

  `:path` may be `nil` for a surface with no UI to drive; it then has no generated
  test and needs a waiver, so the omission is deliberate and visible.

  `:mounted` is the selector proving the page's own content rendered; it defaults to
  `[data-phx-main]`. `:chain` overrides the span chain the test asserts.
  """

  @enforce_keys [:id]
  defstruct [:id, :path, :actor, :mounted, :chain, actions: []]

  @type t :: %__MODULE__{
          id: String.t(),
          path: String.t() | nil,
          actor: term(),
          mounted: String.t() | nil,
          chain: [AshBrowserTests.Span.matcher()] | nil,
          actions: [AshBrowserTests.Action.t()]
        }
end
