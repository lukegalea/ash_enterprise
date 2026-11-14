defmodule AshEnterprise.Platform.Transformers.DefaultPagination do
  @moduledoc """
  Gives every list read on a platform resource a page size, so nothing that asks
  for a page gets the whole table.

  Ash already gives each `defaults [:read]` action pagination (keyset and offset,
  not required, countable, `max_page_size` 250) but no `default_limit`, and a
  hand-written read gets no pagination at all. Either way a caller that asks for
  a page without a limit, or a surface that pages whatever the action allows,
  gets every row.

  This transformer runs after every other one, so it sees the reads Ash and any
  library extension added, and for each read action:

    * one that is a get (`get? true` or `get_by`) or manual is left alone: a get
      returns one row, and a manual read owns its own bound;
    * one with no pagination gets Ash's own default for a `defaults` read
      (keyset and offset, not required, countable where the data layer can count)
      plus `default_limit` 50 and `max_page_size` 250;
    * one that pages keeps what it names, and gets `default_limit` 50 and
      `max_page_size` 250 for whichever it leaves out.

  Nothing becomes required. `required?` and `paginate_by_default?` stay as the
  action declared them, so an internal `Ash.read!/2` without `page:` still
  returns a list (`AshEnterprise.Security.ActorContext` reads business units that
  way). What changes is what a page means: a `page:` without a `limit` gets
  50 rows, and no requested limit exceeds 250. A surface that must never
  return an unpaged result (the JSON:API index, the GraphQL list) names a read
  whose pagination is `required?`; `test/ash_enterprise/platform/bounded_reads_test.exs`
  checks that every such surface does.

  Pagination is not part of a resource snapshot, so this changes no migration.
  """

  use Spark.Dsl.Transformer

  alias Ash.Resource.Actions.Read
  alias Spark.Dsl.Transformer

  @default_limit 50
  @max_page_size 250

  @doc "The page size a read gets when it names none."
  @spec default_limit() :: pos_integer()
  def default_limit, do: @default_limit

  @doc "The largest page a read serves when it names no `max_page_size` of its own."
  @spec max_page_size() :: pos_integer()
  def max_page_size, do: @max_page_size

  # Last, so it sees every read: Ash's `SetPrimaryActions` adds the `defaults` ones, and
  # library transformers add theirs (the business-event ledger's `DefineLedger` adds six).
  # Nothing caches an action's pagination, so a late change is the one Ash reads.
  @impl true
  def after?(_), do: true

  @impl true
  def transform(dsl) do
    countable? = Ash.DataLayer.data_layer_can?(dsl, {:query_aggregate, :count})

    dsl =
      dsl
      |> Transformer.get_entities([:actions])
      |> Enum.filter(&match?(%Read{}, &1))
      |> Enum.reduce(dsl, fn action, dsl ->
        case paged(action, countable?) do
          nil ->
            dsl

          pagination ->
            Transformer.replace_entity(
              dsl,
              [:actions],
              %{action | pagination: pagination},
              &(match?(%Read{}, &1) and &1.name == action.name)
            )
        end
      end)

    {:ok, dsl}
  end

  @doc """
  The pagination a read action gets, or `nil` when it is left as declared: a get,
  a manual read, or one that already names both a `default_limit` and a
  `max_page_size`.
  """
  @spec paged(Read.t(), boolean()) :: Read.Pagination.t() | nil
  def paged(%Read{} = action, countable?) do
    cond do
      get?(action) or not is_nil(action.manual) ->
        nil

      action.pagination in [nil, false] ->
        Transformer.build_entity!(Ash.Resource.Dsl, [:actions, :read], :pagination,
          required?: false,
          offset?: true,
          keyset?: true,
          countable: countable?,
          default_limit: @default_limit,
          max_page_size: @max_page_size
        )

      is_nil(action.pagination.default_limit) or is_nil(action.pagination.max_page_size) ->
        %{
          action.pagination
          | default_limit: action.pagination.default_limit || @default_limit,
            max_page_size: action.pagination.max_page_size || @max_page_size
        }

      true ->
        nil
    end
  end

  defp get?(%Read{get?: true}), do: true
  defp get?(%Read{get_by: get_by}) when get_by not in [nil, []], do: true
  defp get?(_), do: false
end
