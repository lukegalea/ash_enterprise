defmodule AshEnterprise.Mdm.Validations.GoldenReadable do
  @moduledoc """
  On `MatchCandidate.confirm`: the person confirming may read the golden the
  staged record would merge into.

  Candidates are generated as a system actor, so one can point at a golden
  the steward may not read (Person is owner-only). The queue never lists such
  a candidate (`:review_queue`); this refuses a confirm of one named by id, as
  `Forbidden`, wherever it comes from — the queue, a steward-decision task, a
  direct call.

  The golden is loaded through `golden` as the actor, under Person's read
  policy: absent means they may not read it (or it is gone), and either way it
  is not theirs to merge into. One read per confirm, in the action, never in a
  policy check. A call with no person (a system actor) is left to the person
  gate in the policies, which refuses it.
  """

  use Ash.Resource.Validation

  @impl true
  def validate(changeset, _opts, context) do
    case context.actor do
      %{} = actor ->
        opts = [actor: actor, tenant: changeset.tenant]

        case Ash.load(changeset.data, [:golden], opts) do
          {:ok, %{golden: %{id: _}}} -> :ok
          {:ok, _no_readable_golden} -> {:error, Ash.Error.Forbidden.exception([])}
          {:error, error} -> {:error, error}
        end

      _nobody ->
        :ok
    end
  end
end
