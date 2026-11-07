defmodule AshEnterprise.Execution.Entry.Trace do
  @moduledoc """
  `AshEnterprise.Execution.Entry`'s `trace`: reads the registered sources
  (`AshEnterprise.ExecutionSources`) as the caller and answers their entries in order,
  with a report per source.

  A trace is read in one tenant, and refused without one: the sources' rows are
  organization-scoped, and a read with no tenant applies no organization filter, so a
  grant that reaches everything in a tenant (a tenant Administrator's `:global`) would
  otherwise reach every tenant's rows under the correlation or reference given.
  """

  use Ash.Resource.Actions.Implementation

  alias AshEnterprise.Execution.Entry
  alias AshEnterprise.ExecutionSources

  @impl true
  def run(_input, _opts, %{tenant: nil}),
    do: {:error, Ash.Error.Invalid.TenantRequired.exception(resource: Entry)}

  def run(input, _opts, context) do
    args = input.arguments

    scope = %{
      correlation_id: args[:correlation_id],
      refs: MapSet.new(List.wrap(args[:root_ref]))
    }

    {entries, reports} =
      ExecutionSources.collect(ExecutionSources.all(), scope,
        actor: context.actor,
        tenant: context.tenant,
        cursors: args[:cursors] || %{}
      )

    {:ok, %{entries: Enum.map(entries, &struct!(Entry, &1)), sources: reports}}
  end
end
