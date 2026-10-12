defmodule AshEnterprise.Erasure.Actions.ScopesDigest do
  @moduledoc """
  `Scope.scopes_digest`: the erasure scopes as plain text for a terminal
  transcript (the ACP `erasure` prompt) — kind, label, ref, status, when
  shredded. Read-only: shredding is never offered over ACP; it is a typed
  confirmation on the web surface (`Scope.shred`).
  """

  use Ash.Resource.Actions.Implementation

  alias AshEnterprise.Erasure.Scope
  alias AshEnterprise.Platform.LocalTime

  @impl true
  def run(_input, _opts, context) do
    opts = Ash.Context.to_opts(context)

    Scope
    |> Ash.Query.for_read(:read, %{}, opts)
    |> Ash.Query.sort(status: :asc, inserted_at: :desc)
    |> Ash.read(opts)
    |> case do
      {:ok, scopes} -> {:ok, render(scopes)}
      {:error, error} -> {:error, error}
    end
  end

  @doc false
  def render([]), do: "Erasure scopes — none opened yet."

  def render(scopes) do
    shredded = Enum.count(scopes, &(&1.status == :shredded))

    lines =
      Enum.map(scopes, fn scope ->
        state =
          if scope.status == :shredded,
            do: "SHREDDED #{LocalTime.stamp(scope.shredded_at)}",
            else: "active"

        "  #{scope.kind}:#{scope.ref}  · #{scope.label || "(no label)"}  · #{state}"
      end)

    Enum.join(
      [
        "Erasure scopes — #{length(scopes)} (#{shredded} shredded). Shred from the web only."
        | lines
      ],
      "\n"
    )
  end
end
