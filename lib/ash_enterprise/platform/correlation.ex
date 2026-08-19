defmodule AshEnterprise.Platform.Correlation do
  @moduledoc """
  A correlation id carried for the life of a request, and stamped onto every
  audit event it produces.

  ## Why this matters more than it looks

  An audit trail that records *what* changed but not *which changes happened
  together* cannot reconstruct an operation. One user action routinely writes
  several rows — assigning a role touches the assignment, and a business-unit
  reorganization touches a subtree — and after the fact those rows are
  indistinguishable from several unrelated actions that happened to be close in
  time.

  Dataverse solves this with `audit.transactionid`, documented as carrying *"the
  same GUID for all the audit rows generated in a single transaction"*. This is
  that, plus a `depth` counter borrowed from `plugintracelog` so nested action
  invocations can be told apart from sibling ones.

  ## Why the process dictionary

  The id has to reach `AshEvents` without every action, changeset and code
  interface call threading it explicitly — which would be the kind of
  cross-cutting noise this platform exists to avoid. It is set once per request
  by `AshEnterpriseWeb.Plugs.LoadActorContext` and read by the platform's global
  change.

  The tradeoff is real: process-dictionary state does not cross process
  boundaries, so work handed to a `Task` or an Oban job starts a *new*
  correlation id unless it is passed along deliberately. `with_correlation/2`
  exists for that. This is a genuine limitation rather than an oversight —
  propagating implicitly across processes is how you end up with one correlation
  id spanning an entire server lifetime.
  """

  @key :ash_enterprise_correlation

  @doc """
  The current correlation id, generating and storing one if absent.

  Generating on demand means code paths with no HTTP request — an Oban job, a
  mix task, a test — still produce correlated audit events rather than null ones.
  """
  def id do
    case Process.get(@key) do
      %{id: id} ->
        id

      _ ->
        id = Ash.UUID.generate()
        Process.put(@key, %{id: id, depth: 0})
        id
    end
  end

  @doc "How deeply nested the current action invocation is. Zero at the top."
  def depth do
    case Process.get(@key) do
      %{depth: depth} -> depth
      _ -> 0
    end
  end

  @doc """
  Runs `fun` under an explicit correlation id.

  Use this when handing work to another process — a `Task`, an Oban worker — so
  the audit events it writes join the originating operation instead of forming an
  orphaned group.
  """
  def with_correlation(id, fun) when is_binary(id) and is_function(fun, 0) do
    previous = Process.get(@key)
    Process.put(@key, %{id: id, depth: 0})

    try do
      fun.()
    after
      if previous, do: Process.put(@key, previous), else: Process.delete(@key)
    end
  end

  @doc "Starts a fresh correlation scope. Called once per request."
  def start_new do
    id = Ash.UUID.generate()
    Process.put(@key, %{id: id, depth: 0})
    id
  end

  @doc false
  def increment_depth do
    current = Process.get(@key) || %{id: Ash.UUID.generate(), depth: 0}
    Process.put(@key, %{current | depth: current.depth + 1})
    current.depth + 1
  end

  @doc """
  The metadata stamped onto every audit event.

  `system_actor` is included here because a system actor cannot be persisted as
  a foreign key -- it is a compile-time constant, not a row -- so this is where
  its attribution actually lives. See `AshEnterprise.Platform.SystemActor`.
  """
  def audit_metadata(actor) do
    %{
      "correlation_id" => id(),
      "depth" => depth(),
      "system_actor" => system_actor_name(actor),
      # Present only while someone is acting on another user's behalf, which is
      # what makes it useful: `metadata ? 'impersonator_id'` is the query for
      # "show me every support access this month". See
      # `AshEnterprise.Security.Impersonation`.
      "impersonator_id" => AshEnterprise.Security.Impersonation.impersonator_id(actor)
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp system_actor_name(%AshEnterprise.Platform.SystemActor{} = actor),
    do: AshEnterprise.Platform.SystemActor.to_string(actor)

  defp system_actor_name(_), do: nil
end
