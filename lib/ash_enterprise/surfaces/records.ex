defmodule AshEnterprise.Surfaces.Records do
  @moduledoc """
  Opening one record on its registry surface: what every link resolves to,
  on every transport.

    * the web's deep link, `/app/r/:surface/:id` (`AshEnterpriseWeb.RecordLive`);
    * ACP's `_ash/surface/open` with a `recordId`, and the `open <surface> <id>`
      prompt (`AshEnterprise.Acp.ExtMethods`, `AshEnterprise.Acp.Commands`).

  `open/3` re-authorizes from scratch, as the actor: the surface's door, then
  an authorized read of the record (so an id from a link, a URL or a model is
  only ever a request), then the surface's own context selection
  (`AshA2ui.Info.context_state_for/3`, the same read a click performs).
  Anything the actor may not read is `:not_found` — the caller says "not found
  or not yours" and never distinguishes the two.

  A record lands on the surface that owns it (`Surfaces.record_surface/2`):
  a link resolved per field names the first surface over the resource (a
  conversation link names the Inbox), and a Slack conversation opened through
  it lands in Slack. A surface whose `record_match` admits the record keeps
  it, so a link that names a surface explicitly (`/app/r/mdm_golden/:id`,
  where People is the first surface over Person) opens there.

  The surface key `"record"` is the polymorphic target: its id is a typed
  reference `"<surface>:<id>"` (a task's subject, `subject_ref`), resolved to
  that surface here.
  """

  alias AshEnterprise.Security.ActorContext
  alias AshEnterprise.Surfaces
  alias AshEnterprise.Surfaces.{Doors, Surface}

  @typedoc "An opened record: where it lives, the record, and the surface's selection."
  @type opened :: %{
          surface: Surface.t(),
          record: struct(),
          context_state: map(),
          path: String.t()
        }

  @type error ::
          {:no_surface, String.t()}
          | {:door_closed, String.t()}
          | {:no_detail, Surface.t()}
          | {:no_row, Surface.t(), pos_integer()}
          | :not_found

  @doc """
  Open record `id` on surface `key` (an atom, or a name) for `actor`.
  """
  @spec open(atom() | String.t(), String.t() | nil, term()) :: {:ok, opened()} | {:error, error()}
  def open(key, id, actor)

  def open(key, id, actor) when key in [:record, "record"] do
    case split_ref(id) do
      {:ok, surface_key, record_id} -> open(surface_key, record_id, actor)
      :error -> {:error, :not_found}
    end
  end

  def open(key, id, actor) do
    with {:ok, surface} <- surface(key),
         :ok <- door(surface, actor),
         {:ok, record} <- read(surface, id, actor) do
      surface |> home(record, actor) |> select(record, actor)
    end
  end

  @doc """
  Open the `n`th row of surface `key`'s list, as the actor reads it: the
  surface's own query on its first page (default preset, sort and window),
  then `open/3` on that row's id, so it is re-authorized like any link.
  What `/open <surface> <n>` means on every transport. A row past the first
  page, or a surface with no detail, says so.
  """
  @spec nth(atom() | String.t(), pos_integer(), term()) :: {:ok, opened()} | {:error, error()}
  def nth(key, n, actor) when is_integer(n) and n > 0 do
    with {:ok, surface} <- surface(key),
         :ok <- door(surface, actor),
         {:ok, id} <- row_id(surface, n, actor) do
      open(surface.key, id, actor)
    end
  end

  defp row_id(%Surface{context: nil} = surface, _n, _actor), do: {:error, {:no_detail, surface}}
  defp row_id(%Surface{ui: nil} = surface, _n, _actor), do: {:error, {:no_detail, surface}}

  defp row_id(%Surface{ui: ui} = surface, n, actor) do
    opts = [actor: actor, tenant: ActorContext.tenant(actor), authorize?: true]

    with %{query: %AshA2ui.Query{}} = list <- list(AshA2ui.ResolvedView.resolve(ui, []), surface),
         {:ok, records, _state} <-
           AshA2ui.QueryRunner.run(list, AshA2ui.QueryRunner.default_params(list), opts),
         %{id: id} <- Enum.at(records, n - 1) do
      {:ok, to_string(id)}
    else
      _no_row -> {:error, {:no_row, surface, n}}
    end
  end

  # The list a row number counts in: on a multi-table surface, the table that
  # selects the surface's context (People's directory); else the surface's
  # own query.
  defp list(%{tables: [_ | _] = tables} = view, %Surface{context: context}) do
    Enum.find(tables, view, &(&1.component.select_context == context))
  end

  defp list(view, _surface), do: view

  @doc """
  The surface for `key` behind its door, with no record — what a link to a
  surface that has no detail opens.
  """
  @spec surface_for(atom() | String.t(), term()) :: {:ok, Surface.t()} | {:error, error()}
  def surface_for(key, actor) do
    with {:ok, surface} <- surface(key),
         :ok <- door(surface, actor) do
      {:ok, surface}
    end
  end

  @doc "A person-facing sentence for an `open/3` error."
  @spec message(error()) :: String.t()
  def message({:no_surface, key}), do: "There is no #{key} surface."
  def message({:door_closed, text}), do: text
  def message({:no_detail, surface}), do: "#{surface.label} has no detail to open a record in."
  def message(:not_found), do: "That record was not found, or it is not yours."

  def message({:no_row, surface, n}),
    do: "#{surface.label} has no row #{n} on its first page for you."

  # -- steps --------------------------------------------------------------------

  defp surface(key) do
    case Surfaces.fetch(key) do
      nil -> {:error, {:no_surface, to_string(key)}}
      surface -> {:ok, surface}
    end
  end

  defp door(surface, actor) do
    if Surfaces.open?(surface, actor),
      do: :ok,
      else: {:error, {:door_closed, "#{surface.label} is for #{Doors.audience(surface.door)}."}}
  end

  defp read(%Surface{context: nil} = surface, _id, _actor), do: {:error, {:no_detail, surface}}

  defp read(%Surface{resource: resource}, id, actor) when is_binary(id) and id != "" do
    case Ash.get(resource, id,
           actor: actor,
           tenant: ActorContext.tenant(actor),
           not_found_error?: false
         ) do
      {:ok, %{} = record} -> {:ok, record}
      # Missing, unreadable, malformed: one answer.
      _not_readable -> {:error, :not_found}
    end
  end

  defp read(_surface, _id, _actor), do: {:error, :not_found}

  # The surface that owns this record, when it is another one the actor may
  # open. A surface whose own `record_match` admits the record keeps it: a
  # link that names a second surface over the resource on purpose (the
  # golden-records surface over Person, beside People) lands there.
  defp home(surface, record, actor) do
    if Surfaces.admits?(surface, record),
      do: surface,
      else: elsewhere(surface, record, actor)
  end

  defp elsewhere(surface, record, actor) do
    case Surfaces.record_surface(surface.resource, record) do
      %Surface{} = home when home.key != surface.key ->
        if Surfaces.open?(home, actor), do: home, else: surface

      _same ->
        surface
    end
  end

  defp select(surface, record, actor) do
    context = Atom.to_string(surface.context)
    id = to_string(record.id)

    state =
      AshA2ui.Info.context_state_for(surface.ui, %{context => id},
        actor: actor,
        tenant: ActorContext.tenant(actor)
      )

    case state do
      %{^context => %{"value" => ^id}} ->
        {:ok,
         %{
           surface: surface,
           record: record,
           context_state: state,
           path: surface.path <> "?" <> Plug.Conn.Query.encode(%{"ctx" => %{context => id}})
         }}

      _not_selected ->
        {:error, :not_found}
    end
  end

  defp split_ref(ref) when is_binary(ref) do
    case String.split(ref, ":", parts: 2) do
      [key, id] when key != "" and id != "" -> {:ok, key, id}
      _ -> :error
    end
  end

  defp split_ref(_ref), do: :error
end
