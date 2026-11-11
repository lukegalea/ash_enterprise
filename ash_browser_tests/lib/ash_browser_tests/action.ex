defmodule AshBrowserTests.Action do
  @moduledoc """
  An action on a surface. `:run` receives the session and the test context, already
  on the page, and returns the session. `:setup` runs before the page opens and
  returns the context (seed a row there). `:verify` receives the matched chain and
  the context after the chain assertion. An action with `run: nil` cannot be driven
  and needs a waiver.
  """

  @enforce_keys [:id]
  defstruct [:id, :run, :setup, :chain, :verify]

  @type run :: (struct(), map() -> struct())
  @type t :: %__MODULE__{
          id: String.t(),
          run: run() | nil,
          setup: (map() -> map()) | nil,
          chain: [AshBrowserTests.Span.matcher()] | nil,
          verify: (spans :: [AshBrowserTests.Span.t()], map() -> any()) | nil
        }
end
