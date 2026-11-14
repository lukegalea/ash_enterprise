defmodule AshEnterprise.Security.Preparations.SecuredFieldRefs do
  @moduledoc """
  A filter on a secured column matches only where the reader may see the column.

  A field policy (`AshEnterprise.Platform.Resource`'s `secured_fields`) withholds the
  column's value from the results, and Ash rewrites a filter a client supplied
  (`Ash.Query.filter_input/2`) the same way. A filter the application builds for a
  person is trusted as written, though: a search box that becomes
  `contains(number, ^text)`, or a lookup through a relationship such as
  `credential.number == ^number`, would answer "which row has this number" for someone
  who may not read the number. That is the column, leaked one question at a time.

  So every read of a platform resource that is authorized rewrites each reference to a
  secured column in its filter, on the resource or across a relationship, to
  `if <the column is visible on this row>, do: column, else: nil`, which is what Ash
  does for a client's filter. The visibility is the column grant's own filter
  (`{AshEnterprise.Security.Checks.RoleGrant, field: name}`), read from the precomputed
  `AshEnterprise.Security.ActorContext`: no query. A reader holding the grant at
  `:global`, a system actor, and a read with `authorize?: false` are left as written.

  It runs as a `before_action` hook, after every filter, preparation and policy has been
  applied, so a filter added after the action was built is covered too. Sorting is not
  rewritten: a sort on a secured column orders the rows the reader can see by a value
  they cannot.
  """

  use Ash.Resource.Preparation

  require Ash.Expr
  import Ash.Expr, only: [expr: 1]

  alias AshEnterprise.Security.Checks.RoleGrant

  # It reads the actor's precomputed context and the query, never the clock, and adds
  # nothing a point in time would change.
  @impl true
  def temporal_safe?(_opts), do: true

  @impl true
  def prepare(query, _opts, context) do
    if Map.get(context, :authorize?, false) do
      actor = Map.get(context, :actor)
      Ash.Query.before_action(query, &hide(&1, actor))
    else
      query
    end
  end

  @doc false
  @spec hide(Ash.Query.t(), term()) :: Ash.Query.t()
  def hide(%Ash.Query{filter: nil} = query, _actor), do: query

  def hide(%Ash.Query{} = query, actor) do
    filter =
      Ash.Filter.map(query.filter, &replace(&1, query.resource, query.action, actor))

    if filter == query.filter do
      query
    else
      {:ok, hydrated} =
        Ash.Filter.hydrate_refs(filter, %{resource: query.resource, public?: false})

      %{query | filter: hydrated}
    end
  end

  defp replace(
         %Ash.Query.Ref{attribute: %Ash.Resource.Attribute{name: name}, relationship_path: path} =
           ref,
         resource,
         action,
         actor
       ) do
    target = Ash.Resource.Info.related(resource, path)

    if target && name in secured_fields(target) do
      action = if path == [], do: action, else: Ash.Resource.Info.primary_action(target, :read)

      case RoleGrant.filter(actor, %{resource: target, action: action}, field: name) do
        true ->
          {:halt, ref}

        visible ->
          visible = Ash.Filter.move_to_relationship_path(visible, path)
          {:halt, expr(if ^visible, do: ^ref, else: nil)}
      end
    else
      {:halt, ref}
    end
  end

  # A related `exists` refers to the related resource; an unrelated one to its own.
  defp replace(%Ash.Query.Exists{related?: true} = exists, resource, _action, actor) do
    target = Ash.Resource.Info.related(resource, exists.at_path ++ exists.path)
    {:halt, %{exists | expr: map_within(exists.expr, target, actor)}}
  end

  defp replace(%Ash.Query.Exists{resource: target} = exists, _resource, _action, actor) do
    {:halt, %{exists | expr: map_within(exists.expr, target, actor)}}
  end

  defp replace(other, _resource, _action, _actor), do: other

  defp map_within(expr, nil, _actor), do: expr

  defp map_within(expr, target, actor) do
    Ash.Filter.map(
      expr,
      &replace(&1, target, Ash.Resource.Info.primary_action(target, :read), actor)
    )
  end

  defp secured_fields(resource) do
    if AshEnterprise.Platform.SystemAttributes in Spark.extensions(resource),
      do: Spark.Dsl.Extension.get_opt(resource, [:platform], :secured_fields, []),
      else: []
  end
end
