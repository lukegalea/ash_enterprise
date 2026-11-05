defmodule AshEnterprise.Execution.Actions.RequestInvocation do
  @moduledoc """
  A generic action that asks for a governed target to run, through
  `AshEnterprise.Execution.invoke/4`, instead of running it.

      action :request_assignment, :map do
        argument :user_id, :uuid, allow_nil?: false
        run {AshEnterprise.Execution.Actions.RequestInvocation, target: :assign_governed}
      end

  The action's non-nil arguments are the target's arguments, and the target is the
  action named by `target` on the same resource. `rename` maps an argument to the name
  the target knows it by (`%{record_id: "id"}` for an update's primary key). It runs as
  the caller, so the invocation is theirs and executes as them.

  By default each call is a request of its own, keyed by a fresh UUIDv7, so a repeated
  call asks again rather than returning an earlier row. With `key: "certify"` and
  `key_argument: :record_id` the key is `certify:<record id>` instead: asking again for
  the same record returns the same row, and asking for it with different arguments is an
  `AshAgent.Invocation.IdempotencyConflict`.

  It returns what a caller needs to follow the request, never what it will change:

    * `invocation_id`, `target`, `status` and `error_code` (set when the request was
      rejected);
    * `approval_url`, when the row waits for an approval: the approval task's address
      (`/app/r/approvals/<task id>`, see `AshEnterpriseWeb.RecordController`), for a
      person who may approve it to open. Until the MCP Tasks extension lands, this link
      is how an MCP client learns where its request is waiting.

  Nothing the target does happens here: a request that needs approval changes nothing
  until a person approves it and the `:execute` trigger runs it.
  """

  use Ash.Resource.Actions.Implementation
  use AshEnterpriseWeb, :verified_routes

  alias AshAgent.Invocation.Target
  alias AshEnterprise.Execution

  @impl true
  def run(input, opts, context) do
    target = Target.name(input.resource, Keyword.fetch!(opts, :target))

    rename = Keyword.get(opts, :rename, %{})

    args =
      for {name, value} <- input.arguments,
          not is_nil(value),
          into: %{},
          do: {Map.get(rename, name, to_string(name)), value}

    with {:ok, row} <-
           Execution.invoke(
             target,
             args,
             %{key: key(input, opts)},
             Ash.Context.to_opts(context)
           ) do
      {:ok,
       %{
         "invocation_id" => row.id,
         "target" => row.target,
         "status" => Atom.to_string(row.status),
         "error_code" => row.error_code,
         "approval_url" => approval_url(row)
       }}
    end
  end

  defp key(input, opts) do
    case opts[:key_argument] do
      nil -> "request:" <> Ash.UUIDv7.generate()
      argument -> "#{Keyword.fetch!(opts, :key)}:#{Map.fetch!(input.arguments, argument)}"
    end
  end

  # The task is read without authorization: the requester is not asked to approve their
  # own request, so they may not read it, and only its address leaves here.
  defp approval_url(%{status: :awaiting_approval} = row) do
    case Ash.load(row, :approval_task, authorize?: false) do
      {:ok, %{approval_task: %{id: id}}} -> url(~p"/app/r/approvals/#{id}")
      _no_task -> nil
    end
  end

  defp approval_url(_row), do: nil
end
