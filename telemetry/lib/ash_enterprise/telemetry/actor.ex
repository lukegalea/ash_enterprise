defmodule AshEnterprise.Telemetry.Actor do
  @moduledoc """
  Who is acting, on every span: the signed-in person and their tenant.

  The host calls `put/1` once where it learns the actor, in a plug after
  authentication and in a LiveView `on_mount`:

      AshEnterprise.Telemetry.Actor.put(
        id: user.id,
        role: "manager",
        name: to_string(user.email),
        tenant_id: org.id,
        tenant_name: org.name
      )

  From then on `AshEnterprise.Telemetry.SpanProcessor` stamps every span the process
  starts, and `put/1` stamps the span already open (the request or LiveView mount span,
  which started before the actor was known). A job enqueued by the process carries the
  actor in its meta (`AshEnterprise.Telemetry.ObanEngine`) and the job's spans get it
  back; `AshEnterprise.Telemetry.TaskContext` carries it into a `Task`. Sentry's user
  context is set to the same `id` (and `username`, when names are on).

  | Attribute | From | |
  |---|---|---|
  | `enduser.id` | `:id` | OpenTelemetry semantic convention |
  | `enduser.role` | `:role` | Omitted when not given |
  | `enduser.name` | `:name` | **Only when** `config :ash_enterprise_telemetry, :enduser_name?, true` |
  | `app.tenant.id` | `:tenant_id` | |
  | `app.tenant.name` | `:tenant_name` | A readable slug or name |

  `enduser.name` is personal data, so it is off by default: turn it on where the data is
  synthetic (development and test), and production spans carry ids only.

  These are the server's word for who acted. A browser span carries the same keys from
  the page's `otel-enduser` meta tag (`meta_content/0`), which is what the page claims,
  not something the server verified.
  """

  @key {__MODULE__, :attributes}
  @fields [
    id: :"enduser.id",
    role: :"enduser.role",
    name: :"enduser.name",
    tenant_id: :"app.tenant.id",
    tenant_name: :"app.tenant.name"
  ]
  @max_bytes 256

  @doc "Sets the actor for this process and stamps the current span. Never raises."
  @spec put(keyword() | map()) :: :ok
  def put(actor) when is_list(actor) or is_map(actor) do
    attributes = attributes(actor)
    Process.put(@key, attributes)
    stamp_current_span(attributes)
    set_sentry_user(attributes)
    :ok
  catch
    _kind, _reason -> :ok
  end

  @doc """
  Restores attributes taken from `current/0` in another process (a job, a task). Spans
  started afterwards carry them; an open span is left alone.
  """
  @spec restore(map() | nil) :: :ok
  def restore(attributes) when is_map(attributes) and map_size(attributes) > 0 do
    attributes =
      for {key, value} <- attributes,
          key = known_key(key),
          not is_nil(key),
          is_binary(value),
          name_allowed?(key),
          into: %{},
          do: {key, value}

    Process.put(@key, attributes)
    set_sentry_user(attributes)
    :ok
  catch
    _kind, _reason -> :ok
  end

  def restore(_none) do
    Process.delete(@key)
    :ok
  end

  @doc "The attributes for this process, or an empty map."
  @spec current() :: %{optional(atom()) => String.t()}
  def current, do: Process.get(@key, %{})

  @doc "Forgets the actor."
  @spec clear() :: :ok
  def clear do
    Process.delete(@key)
    :ok
  end

  @doc "Whether `enduser.name` is recorded."
  @spec name_enabled?() :: boolean()
  def name_enabled?, do: Application.get_env(:ash_enterprise_telemetry, :enduser_name?, false)

  @doc """
  The JSON for the root layout's `<meta name="otel-enduser" content="...">`, from which
  the browser tracer stamps its spans. Empty when no actor is set.
  """
  @spec meta_content() :: String.t()
  def meta_content do
    case current() do
      empty when map_size(empty) == 0 ->
        ""

      attributes ->
        Jason.encode!(Map.new(attributes, fn {key, value} -> {to_string(key), value} end))
    end
  end

  @doc false
  def attributes(actor) do
    for {field, key} <- @fields,
        name_allowed?(key),
        value = text(get(actor, field)),
        not is_nil(value),
        into: %{},
        do: {key, value}
  end

  defp get(actor, field) when is_list(actor), do: Keyword.get(actor, field)
  defp get(actor, field) when is_map(actor), do: Map.get(actor, field)

  defp text(nil), do: nil
  defp text(""), do: nil
  defp text(value) when is_binary(value), do: String.slice(value, 0, @max_bytes)
  defp text(value) when is_atom(value), do: Atom.to_string(value)
  defp text(value), do: value |> to_string() |> String.slice(0, @max_bytes)

  defp name_allowed?(:"enduser.name"), do: name_enabled?()
  defp name_allowed?(_key), do: true

  defp known_key(key) when is_atom(key), do: if(key in Keyword.values(@fields), do: key)

  defp known_key(key) when is_binary(key) do
    Enum.find(Keyword.values(@fields), &(Atom.to_string(&1) == key))
  end

  defp known_key(_key), do: nil

  defp stamp_current_span(attributes) when map_size(attributes) > 0 do
    span = OpenTelemetry.Tracer.current_span_ctx()
    OpenTelemetry.Span.set_attributes(span, attributes)
  end

  defp stamp_current_span(_attributes), do: :ok

  defp set_sentry_user(attributes) do
    if Code.ensure_loaded?(Sentry.Context) do
      user =
        %{}
        |> put_present(:id, attributes[:"enduser.id"])
        |> put_present(:username, attributes[:"enduser.name"])

      if map_size(user) > 0, do: Sentry.Context.set_user_context(user)
    end
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)
end
