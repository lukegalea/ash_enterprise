defmodule AshEnterprise.Artifacts.Differ do
  @moduledoc """
  A semantic differ: compares two versions of one artifact type by what they
  mean, never by their text.

  `aspects/0` says what it compares, in the order the diff page shows them,
  each with a label; the page lists them, so a reader knows what a short diff
  covers. `diff/3` returns the changes between the older and the newer version.
  It may read (a release manifest reads the agents it pins) and does so as the
  viewer, through `opts` (`:actor`, `:tenant`).

  A differ returns `{:ok, []}` only when it compared both versions and found
  nothing it covers that changed; `AshEnterprise.Artifacts.diff/4` still
  checks the content hashes, so a change the differ does not cover is reported
  as such and not as "no changes". It returns `{:error, reason}` when it could
  not compare, and that is shown as a failure.
  """

  alias AshEnterprise.Artifacts.Change

  @callback aspects() :: [{atom(), String.t()}]
  @callback diff(old :: struct(), new :: struct(), opts :: keyword()) ::
              {:ok, [Change.t()]} | {:error, term()}
end
