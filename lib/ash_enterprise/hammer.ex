defmodule AshEnterprise.Hammer do
  @moduledoc """
  Rate-limiter backend over ETS, used by the provider webhook plug.

  ETS means the limit is per node. That is the right default for a template and
  the wrong one for a horizontally scaled deployment, where two nodes each grant
  the full allowance; swap the backend for Redis before relying on it as a
  control rather than a courtesy.
  """
  use Hammer, backend: :ets
end
