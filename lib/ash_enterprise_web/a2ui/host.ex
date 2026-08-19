defmodule AshEnterpriseWeb.A2ui.Host do
  @moduledoc """
  Hosts an A2UI surface inside a LiveView that is not otherwise an A2UI
  LiveView.

  `AshA2ui.LiveRenderer` is the batteries-included transport and is what
  `AshEnterpriseWeb.A2uiLive` uses: one surface, chosen at compile time, for the
  whole module. `AshEnterpriseWeb.AgentLive` cannot use it, for two reasons that
  are both structural rather than stylistic:

    * it does not know which surface it will show until somebody asks, and
    * the surface it shows may be one the helper agent *composed*, which is an
      `%AshA2ui.Dynamic.Surface{}` rather than a UI module — a shape
      `LiveRenderer` has no way to take.

  So this is the small amount of `LiveRenderer` that AgentLive needs, written
  over both shapes. It deliberately does **not** reach for `LiveRenderer`'s
  `surface_fn`/`data_model_fn` options, which are documented there as test seams
  that applications must not rely on.

  ## What a presentation is

  A `%Presentation{}` names one surface and everything needed to keep it live:
  which topics to listen on, and the last `/query` state the client was sent so
  a background refresh re-runs the viewer's current search and page rather than
  resetting them.

  Surface *contexts* are not tracked. No surface in this application declares
  one, and carrying state for a feature nothing uses would be untested code that
  looks load-bearing. `AshA2ui.LiveRenderer` does track them, and is the thing to
  copy from if a context surface ever needs hosting here.
  """

  import Phoenix.LiveView, only: [push_event: 3]

  alias AshEnterpriseWeb.A2ui.Surfaces

  @messages_event "a2ui:messages"
  @refresh_message {:ash_a2ui_host, :refresh}
  @debounce_ms 150

  defmodule Presentation do
    @moduledoc "One hosted surface: what it is, what it listens to, and where the client got to."

    @enforce_keys [:kind, :surface, :title]
    defstruct [:kind, :surface, :title, :subtitle, topics: [], query_state: nil]

    @type t :: %__MODULE__{
            kind: :declared | :dynamic,
            surface: module() | struct(),
            title: String.t(),
            subtitle: String.t() | nil,
            topics: [String.t()],
            query_state: map() | nil
          }
  end

  @doc "A presentation of one of the declared surfaces from the registry."
  @spec declared(map()) :: Presentation.t()
  def declared(surface) do
    %Presentation{
      kind: :declared,
      surface: surface.ui,
      title: surface.label,
      subtitle: surface.blurb,
      topics: Surfaces.topics(surface)
    }
  end

  @doc """
  A presentation of a surface the agent composed.

  Its topics come from the resource it was composed over, exactly as a declared
  surface's do — an ad-hoc table over a resource that publishes is live for the
  same reason and by the same mechanism. Nothing about being composed at runtime
  makes a surface less able to update itself.
  """
  @spec dynamic(struct(), String.t()) :: Presentation.t()
  def dynamic(%{} = surface, title) do
    %Presentation{
      kind: :dynamic,
      surface: surface,
      title: title,
      subtitle: "Composed for this request. Every name in it was checked against the schema.",
      topics: Surfaces.topics(surface.resource)
    }
  end

  @doc """
  Subscribes to the presentation's topics and pushes the surface to the client.

  Returns the presentation with its `/query` state recorded, so the caller can
  hold it in an assign.
  """
  @spec present(Phoenix.LiveView.Socket.t(), Presentation.t(), keyword()) ::
          {Phoenix.LiveView.Socket.t(), Presentation.t()}
  def present(socket, %Presentation{} = presentation, opts) do
    Enum.each(presentation.topics, &Phoenix.PubSub.subscribe(AshEnterprise.PubSub, &1))

    messages = build_surface(presentation, opts)

    {push_messages(socket, messages), track_query(presentation, messages)}
  end

  @doc """
  Unsubscribes from a presentation's topics.

  Called before presenting a different surface. Without it, asking for three
  surfaces in a row leaves the LiveView subscribed to all three, and a write to
  any of them refreshes a surface nobody is looking at.
  """
  @spec dismiss(Presentation.t() | nil) :: :ok
  def dismiss(nil), do: :ok

  def dismiss(%Presentation{topics: topics}) do
    Enum.each(topics, &Phoenix.PubSub.unsubscribe(AshEnterprise.PubSub, &1))
  end

  @doc """
  Rebuilds the data model and pushes it, carrying the client's current query
  state.

  This is a *data-only* refresh: the surface's components are already on the
  client and do not change, so only the rows are sent.
  """
  @spec refresh(Phoenix.LiveView.Socket.t(), Presentation.t(), keyword()) ::
          {Phoenix.LiveView.Socket.t(), Presentation.t()}
  def refresh(socket, %Presentation{} = presentation, opts) do
    data_model = build_data_model(presentation, with_query_state(opts, presentation))

    {push_messages(socket, [data_model]), track_query(presentation, [data_model])}
  end

  @doc """
  Routes a client action envelope through the right handler and pushes the
  follow-up messages.

  Never invokes an Ash action directly: the handler is what enforces the
  row-action allowlist, `visible_when`, and the error contract that puts
  validation messages on the reserved `/errors/<field>` paths.
  """
  @spec handle_action(Phoenix.LiveView.Socket.t(), Presentation.t(), map(), keyword()) ::
          {Phoenix.LiveView.Socket.t(), Presentation.t()}
  def handle_action(socket, %Presentation{kind: :declared} = presentation, envelope, opts) do
    presentation.surface
    |> AshA2ui.ActionHandler.handle(envelope, opts)
    |> apply_action_result(socket, presentation)
  end

  def handle_action(socket, %Presentation{kind: :dynamic} = presentation, envelope, opts) do
    presentation.surface
    |> AshA2ui.Dynamic.handle_action(envelope, opts)
    |> apply_action_result(socket, presentation)
  end

  @doc """
  Schedules a debounced refresh, coalescing a burst of notifications into one.

  Returns `{:already_scheduled, socket}` when a refresh is already pending, so
  the caller does not stack timers. The message to expect back is
  `refresh_message/0`.
  """
  @spec schedule_refresh(boolean()) :: :scheduled | :already_scheduled
  def schedule_refresh(true), do: :already_scheduled

  def schedule_refresh(false) do
    Process.send_after(self(), @refresh_message, @debounce_ms)
    :scheduled
  end

  @doc "The message `schedule_refresh/1` sends back when the debounce window closes."
  @spec refresh_message() :: term()
  def refresh_message, do: @refresh_message

  # --- internals --------------------------------------------------------------

  defp build_surface(%Presentation{kind: :declared, surface: ui}, opts),
    do: AshA2ui.Info.build_surface(ui, opts)

  defp build_surface(%Presentation{kind: :dynamic, surface: surface}, opts),
    do: AshA2ui.Dynamic.build_surface(surface, opts)

  defp build_data_model(%Presentation{kind: :declared, surface: ui}, opts),
    do: AshA2ui.Info.build_data_model(ui, opts)

  defp build_data_model(%Presentation{kind: :dynamic, surface: surface}, opts),
    do: AshA2ui.Dynamic.build_data_model(surface, opts)

  defp apply_action_result({result, messages}, socket, presentation)
       when result in [:ok, :error] do
    {push_messages(socket, messages), track_query(presentation, messages)}
  end

  defp push_messages(socket, messages),
    do: push_event(socket, @messages_event, %{messages: messages})

  defp with_query_state(opts, %Presentation{query_state: nil}), do: opts

  defp with_query_state(opts, %Presentation{query_state: state}),
    do: [{:query_state, state} | opts]

  # The client's `/query` state, read back out of whatever was last pushed to
  # it. Mirrors `AshA2ui.LiveRenderer`'s tracking: the full data model carries it
  # under "query", an action follow-up updates that path directly, and a v1.0
  # surface inlines it in `createSurface`.
  defp track_query(presentation, messages) do
    state =
      Enum.reduce(messages, presentation.query_state, fn
        %{"updateDataModel" => %{"path" => "/query", "value" => value}}, _acc
        when is_map(value) ->
          value

        %{"updateDataModel" => %{"path" => "/", "value" => %{"query" => value}}}, _acc
        when is_map(value) ->
          value

        %{"createSurface" => %{"dataModel" => %{"query" => value}}}, _acc when is_map(value) ->
          value

        _message, acc ->
          acc
      end)

    %{presentation | query_state: state}
  end
end
