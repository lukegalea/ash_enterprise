defmodule AshEnterpriseWeb.Decisions.TryLive do
  @moduledoc """
  Try a decision version against sample inputs before publishing it.

  Reached from the decision catalogue. Pick a version (the draft or any published one), type a
  value for each declared input, and see the answer, which rules matched and the hit policy
  that reduced them. A trial records nothing: see `AshEnterprise.Decisions.Trial`.

  Every event re-reads the chosen version as the signed-in person, in their tenant, through
  the definition's read policy, rather than trusting an id or struct held in the socket. A
  version the person may not read, including any version of another tenant's decision, is
  refused the same way a missing one is.
  """

  use AshEnterpriseWeb, :live_view

  alias AshEnterprise.Decisions.Trial

  @impl true
  def mount(%{"key" => key}, _session, socket) do
    {:ok,
     socket
     |> assign(:key, key)
     |> assign(:page_title, dgettext("default", "Try %{key}", key: key))
     |> assign(:versions, [])
     |> assign(:selected, nil)
     |> assign(:decision_names, [])
     |> assign(:decision, nil)
     |> assign(:declared, [])
     |> assign(:raw, %{})
     |> assign(:field_errors, %{})
     |> assign(:outcome, nil)}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    versions = Trial.versions(socket.assigns.key, actor(socket), tenant(socket))

    socket =
      socket
      |> assign(:versions, versions)
      |> select(versions |> default_version() |> maybe_id())

    {:noreply, socket}
  end

  @impl true
  def handle_event("select_version", %{"version" => id}, socket),
    do: {:noreply, select(socket, id)}

  def handle_event("select_decision", %{"decision" => name}, socket) do
    {:noreply, socket |> assign(:decision, name) |> assign(:outcome, nil)}
  end

  def handle_event("try", params, socket) do
    case fresh(socket, params["version"]) do
      nil ->
        {:noreply, assign(socket, :outcome, {:refused, nil})}

      definition ->
        raw = Map.get(params, "inputs", %{})
        socket = socket |> assign(:raw, raw) |> assign(:selected, definition)
        {:noreply, run(socket, definition, raw)}
    end
  end

  defp run(socket, definition, raw) do
    declared = Trial.inputs(definition)

    case Trial.cast(declared, raw) do
      {:error, errors} ->
        socket |> assign(:field_errors, errors) |> assign(:outcome, nil)

      {:ok, inputs} ->
        outcome =
          case Trial.run(definition, inputs, socket.assigns.decision) do
            {:ok, result} -> {:ok, result}
            {:error, reason} -> {:error, reason}
          end

        socket |> assign(:field_errors, %{}) |> assign(:outcome, outcome)
    end
  end

  defp select(socket, nil), do: assign(socket, :selected, nil)

  defp select(socket, id) do
    case fresh(socket, id) do
      nil ->
        assign(socket, :selected, nil)

      definition ->
        names = Trial.decisions(definition)

        socket
        |> assign(:selected, definition)
        |> assign(:decision_names, names)
        |> assign(:decision, List.first(names))
        |> assign(:declared, Trial.inputs(definition))
        |> assign(:raw, %{})
        |> assign(:field_errors, %{})
        |> assign(:outcome, nil)
    end
  end

  defp fresh(socket, id) when is_binary(id),
    do: Trial.version(socket.assigns.key, id, actor(socket), tenant(socket))

  defp fresh(_socket, _id), do: nil

  # The draft is the thing someone is about to publish, so it is what they most want to try.
  defp default_version(versions),
    do: Enum.find(versions, &(&1.status == :draft)) || List.first(versions)

  defp maybe_id(nil), do: nil
  defp maybe_id(definition), do: definition.id

  defp actor(socket), do: socket.assigns[:current_user]
  defp tenant(socket), do: socket.assigns[:current_tenant]

  defp version_label(definition) do
    dgettext("default", "v%{version} (%{status})",
      version: definition.version,
      status: status_label(definition.status)
    )
  end

  defp status_label(:draft), do: dgettext("default", "draft")
  defp status_label(:published), do: dgettext("default", "published")
  defp status_label(:retired), do: dgettext("default", "retired")
  defp status_label(other), do: to_string(other)

  defp field_error(:blank), do: dgettext("default", "Enter a value.")
  defp field_error(:not_a_number), do: dgettext("default", "Enter a number, like 42 or 3.5.")
  defp field_error(:not_a_boolean), do: dgettext("default", "Enter true or false.")
  defp field_error(:not_a_date), do: dgettext("default", "Enter a date as YYYY-MM-DD.")

  defp engine_error({:evaluation_timeout, _ms}),
    do: dgettext("default", "The decision took too long to evaluate.")

  defp engine_error({:no_decisions, _key}),
    do:
      dgettext("default", "This version has no decision to evaluate. Fix it in the editor first.")

  defp engine_error({:ambiguous_decision, _key, _names}),
    do: dgettext("default", "Choose which decision to evaluate.")

  defp engine_error({:model_load_failed, _}),
    do: dgettext("default", "This version could not be loaded. Fix it in the editor first.")

  defp engine_error(reason),
    do:
      dgettext("default", "The decision could not be evaluated: %{reason}",
        reason: inspect(reason, limit: 8, printable_limit: 200)
      )

  defp format_value(%Decimal{} = value), do: Decimal.to_string(value, :normal)
  defp format_value(value) when is_binary(value), do: value
  defp format_value(value), do: inspect(value, limit: 20, printable_limit: 200)

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      page={assigns[:page]}
      current_scope={assigns[:current_scope]}
      width="max-w-4xl"
    >
      <div class="space-y-6" id="decision-try">
        <div>
          <h1 class="text-2xl font-heading">{dgettext("default", "Try %{key}", key: @key)}</h1>
          <p class="max-w-3xl text-sm text-foreground/70">
            {dgettext(
              "default",
              "Run a version against sample inputs. Nothing is recorded: a trial is not a decision about a case."
            )}
          </p>
        </div>

        <p
          :if={@versions == [] or @outcome == {:refused, nil}}
          id="decision-try-refused"
          class="text-sm"
        >
          {dgettext("default", "There is no version of this decision that you can try.")}
        </p>

        <div :if={@versions != []} class="space-y-4">
          <form id="decision-try-version-form" phx-change="select_version" class="space-y-1">
            <label for="decision-try-version" class="block text-sm font-medium">
              {dgettext("default", "Version")}
            </label>
            <select
              id="decision-try-version"
              name="version"
              class="w-full rounded-md border px-2 py-1"
            >
              <option :for={v <- @versions} value={v.id} selected={@selected && @selected.id == v.id}>
                {version_label(v)}
              </option>
            </select>
          </form>

          <form
            :if={@selected}
            id="decision-try-form"
            phx-submit="try"
            phx-change="select_decision"
            class="space-y-4"
          >
            <input type="hidden" name="version" value={@selected.id} />

            <div :if={length(@decision_names) > 1} class="space-y-1">
              <label for="decision-try-decision" class="block text-sm font-medium">
                {dgettext("default", "Decision")}
              </label>
              <select
                id="decision-try-decision"
                name="decision"
                class="w-full rounded-md border px-2 py-1"
              >
                <option :for={name <- @decision_names} value={name} selected={name == @decision}>
                  {name}
                </option>
              </select>
            </div>

            <p
              :if={@selected.errors not in [nil, []]}
              id="decision-try-compile-errors"
              class="text-sm text-red-700"
            >
              {dgettext(
                "default",
                "This version has errors and cannot be tried until they are fixed in the editor."
              )}
            </p>

            <p
              :if={@declared == [] and @selected.errors in [nil, []]}
              id="decision-try-no-inputs"
              class="text-sm text-foreground/70"
            >
              {dgettext("default", "This decision declares no inputs.")}
            </p>

            <div :for={input <- @declared} class="space-y-1">
              <label for={"decision-try-input-#{input.name}"} class="block text-sm font-medium">
                {input.name}
                <span :if={input.type} class="font-mono text-xs text-foreground/60">{input.type}</span>
              </label>
              <input
                id={"decision-try-input-#{input.name}"}
                type="text"
                name={"inputs[#{input.name}]"}
                value={@raw[input.name]}
                class="w-full rounded-md border px-2 py-1"
              />
              <p
                :if={@field_errors[input.name]}
                id={"decision-try-error-#{input.name}"}
                class="text-sm text-red-700"
              >
                {field_error(@field_errors[input.name])}
              </p>
            </div>

            <button id="decision-try-submit" type="submit" class="rounded-md border px-3 py-1 text-sm">
              {dgettext("default", "Try it")}
            </button>
          </form>

          <div
            :if={match?({:ok, _}, @outcome)}
            id="decision-try-result"
            class="space-y-2 rounded-md border p-4"
          >
            <% {:ok, result} = @outcome %>
            <h2 class="text-lg font-heading">{dgettext("default", "Result")}</h2>
            <p id="decision-try-outputs" class="font-mono text-sm">{format_value(result.outputs)}</p>
            <p class="text-xs text-foreground/60">
              {dgettext("default", "Decision %{decision}, version %{version}",
                decision: result.decision,
                version: result.definition_version
              )}
              <span :if={result.hit_policy}>
                {dgettext("default", "hit policy %{policy}", policy: result.hit_policy)}
              </span>
            </p>
            <h3 class="text-sm font-medium">{dgettext("default", "Rules that matched")}</h3>
            <p
              :if={result.matched_rules == []}
              id="decision-try-no-rules"
              class="text-sm text-foreground/70"
            >
              {dgettext("default", "No rule matched.")}
            </p>
            <ul id="decision-try-rules" class="list-disc pl-5 text-sm">
              <li :for={rule <- result.matched_rules} id={"decision-try-rule-#{rule.id}"}>
                <span :if={rule.position}>{dgettext("default", "Rule %{position}",
                  position: rule.position
                )}</span>
                <span class="font-mono text-xs">{rule.id}</span>
                <span :if={rule.description}>{rule.description}</span>
              </li>
            </ul>
          </div>

          <p :if={match?({:error, _}, @outcome)} id="decision-try-error" class="text-sm text-red-700">
            <% {:error, reason} = @outcome %>
            {engine_error(reason)}
          </p>
        </div>

        <.link navigate={~p"/app/decisions"} class="text-sm underline" id="decision-try-back">
          {dgettext("default", "Every decision")}
        </.link>
      </div>
    </Layouts.app>
    """
  end
end
