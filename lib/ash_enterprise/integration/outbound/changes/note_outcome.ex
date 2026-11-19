defmodule AshEnterprise.Integration.Outbound.Changes.NoteOutcome do
  @moduledoc """
  What a delivery's end does to its endpoint:

    * `:delivered` resets the run of dead-lettered deliveries;
    * `:dead` extends it, and the third in a row sets the endpoint `failing`
      (`"repeated_dead_letters"`);
    * `:egress_refused` sets the endpoint `failing` at once, with the guard's code: a URL
      that resolves to a non-public address will not start resolving correctly by being
      retried.

  `enable` is how a person turns a failing endpoint back on.
  """

  use Ash.Resource.Change

  @dead_limit 3

  @doc "Dead-lettered deliveries in a row that disable an endpoint."
  def dead_limit, do: @dead_limit

  @impl true
  def change(changeset, _opts, _context) do
    outcome = Ash.Changeset.get_argument(changeset, :outcome)
    code = Ash.Changeset.get_argument(changeset, :code)
    apply_outcome(changeset, outcome, code, changeset.data)
  end

  defp apply_outcome(changeset, :delivered, _code, _endpoint),
    do: Ash.Changeset.force_change_attribute(changeset, :consecutive_dead, 0)

  defp apply_outcome(changeset, :dead, _code, endpoint) do
    dead = endpoint.consecutive_dead + 1
    changeset = Ash.Changeset.force_change_attribute(changeset, :consecutive_dead, dead)

    if dead >= @dead_limit and endpoint.status == :active,
      do: failing(changeset, "repeated_dead_letters"),
      else: changeset
  end

  defp apply_outcome(changeset, :egress_refused, code, endpoint) do
    if endpoint.status == :active,
      do: failing(changeset, code || "egress_refused"),
      else: changeset
  end

  defp failing(changeset, reason) do
    changeset
    |> Ash.Changeset.force_change_attribute(:status, :failing)
    |> Ash.Changeset.force_change_attribute(:status_reason, reason)
  end
end
