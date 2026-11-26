defmodule AshEnterpriseWeb.ShowcaseLive.Search do
  @moduledoc """
  The showcase's three-valued search beat (`/app/showcase/search`,
  `AshEnterprise.Showcase.Search`): write or pick a filter that includes a judged
  predicate, and read the result as three groups, in, out and unknown, each unknown with
  its reason. Unknown is never folded into either side.

  The filter is shown as CQL2 (Basic, JSON) in a text box, and it is what runs: a search in
  words only fills the box with a candidate, and nothing runs until the person presses
  "Approve and run" on the text as it stands. The searched clinicians and their facts are
  synthetic, seeded into the demo tenant; a search reads those facts and calls no model.

  Copy is in English and French (`?locale=fr`), through the `showcase` Gettext domain.
  """

  use AshEnterpriseWeb, :live_view

  alias AshEnterprise.Security.ActorContext
  alias AshEnterprise.Showcase
  alias AshEnterprise.Showcase.Search
  alias AshEnterprise.SystemOne.FilterProposal
  alias AshEnterpriseWeb.Layouts

  @locales ~w(en fr)

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       locale: "en",
       model_mode: Showcase.model_mode(),
       names: Map.new(Search.subjects(), &{&1.id, &1}),
       presets: Search.presets(),
       words: "",
       text: "",
       proposal: nil,
       result: nil,
       error: nil
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    locale = if params["locale"] in @locales, do: params["locale"], else: "en"
    Gettext.put_locale(AshEnterpriseWeb.Gettext, locale)
    {:noreply, assign(socket, locale: locale)}
  end

  @impl true
  def handle_event("pick", %{"id" => id}, socket) do
    case Enum.find(socket.assigns.presets, &(&1.id == id)) do
      nil ->
        {:noreply, socket}

      preset ->
        {:noreply, assign(socket, text: pretty(preset.document), proposal: nil, error: nil)}
    end
  end

  def handle_event("edit", %{"search" => %{"text" => text}}, socket),
    do: {:noreply, assign(socket, text: text)}

  def handle_event("propose", %{"words" => %{"words" => words}}, socket) do
    with_access(socket, &propose(&1, words))
  end

  def handle_event("run", %{"search" => %{"text" => text}}, socket) do
    with_access(socket, &run(&1, text))
  end

  # Proposing, approving and running a filter are a person's acts (the policies of
  # `FilterProposal` say so); the page asks before it tries.
  defp with_access(socket, fun) do
    if Ash.can?({FilterProposal, :propose}, actor(socket)) do
      {:noreply, fun.(socket)}
    else
      {:noreply,
       assign(socket,
         result: nil,
         error: dgettext("showcase", "Only a person may propose, approve and run a filter.")
       )}
    end
  end

  defp propose(socket, words) do
    case Search.propose_words(words, actor(socket), tenant(socket)) do
      {:ok, %{status: :proposed, document: document} = proposal} ->
        assign(socket, words: words, text: pretty(document), proposal: proposal, error: nil)

      {:ok, %{refusal_reason: reason}} ->
        assign(socket, words: words, proposal: nil, error: reason)

      {:error, :not_recorded} ->
        assign(socket,
          words: words,
          proposal: nil,
          error:
            dgettext(
              "showcase",
              "No filter was recorded for those words. Pick a filter or write one."
            )
        )

      {:error, error} ->
        assign(socket, words: words, proposal: nil, error: inspect(error))
    end
  end

  defp run(socket, text) do
    case Search.run(text, socket.assigns.proposal, actor(socket), tenant(socket)) do
      {:ok, result} -> assign(socket, text: text, result: result, error: nil)
      {:error, reason} -> assign(socket, text: text, result: nil, error: reason)
    end
  end

  defp actor(socket), do: socket.assigns.current_user
  defp tenant(socket), do: ActorContext.tenant(socket.assigns.current_user)

  defp empty?(%{partitions: partitions}), do: partitions |> Map.values() |> Enum.all?(&(&1 == []))

  defp pretty(document), do: Jason.encode!(document, pretty: true)

  defp subject(%{"subject_id" => id}, names), do: names[id]

  defp predicate_label("city"), do: dgettext("showcase", "city")

  defp predicate_label(_question), do: dgettext("showcase", "licence scan legible")

  defp reason("no_fact"), do: dgettext("showcase", "never assessed")
  defp reason("expired"), do: dgettext("showcase", "its fact has expired")

  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :blurb, :string, required: true
  attr :rows, :list, required: true
  attr :names, :map, required: true

  defp group(assigns) do
    ~H"""
    <section
      id={@id}
      data-count={length(@rows)}
      class="space-y-2 rounded-base border-2 border-border p-3"
    >
      <h3 class="font-heading">{@title} ({length(@rows)})</h3>
      <p class="text-sm text-foreground/70">{@blurb}</p>
      <ul class="space-y-1 text-sm">
        <li
          :for={row <- @rows}
          id={"#{@id}-#{row["subject_id"]}"}
          data-subject={row["subject_id"]}
        >
          <span class="font-medium">{subject(row, @names).name}</span>
          <span class="text-foreground/70">{subject(row, @names).city}</span>
          <span
            :for={{predicate, why} <- Map.get(row, "reasons", %{})}
            data-reason={why}
            class="italic"
          >
            ({predicate_label(predicate)}: {reason(why)})
          </span>
        </li>
      </ul>
    </section>
    """
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} page={assigns[:page]} width="max-w-5xl">
      <:toolbar>
        <nav id="search-locale" class="flex gap-2 text-sm" aria-label="Language">
          <.link
            patch={~p"/app/showcase/search?locale=en"}
            aria-current={@locale == "en" && "true"}
            class={["underline", @locale == "en" && "font-heading"]}
          >
            English
          </.link>
          <.link
            patch={~p"/app/showcase/search?locale=fr"}
            aria-current={@locale == "fr" && "true"}
            class={["underline", @locale == "fr" && "font-heading"]}
          >
            Français
          </.link>
        </nav>
      </:toolbar>

      <div class="space-y-6">
        <header class="space-y-1">
          <h2 class="font-heading text-lg">{dgettext("showcase", "Search with three answers")}</h2>
          <p class="text-sm text-foreground/70">
            {dgettext(
              "showcase",
              "A search over nine invented clinicians. Whether a licence scan is legible is a judged predicate: for some clinicians nobody has judged it yet, or the judgment has expired. Those are neither in nor out: they are unknown, and the result says so, with the reason."
            )}
          </p>
          <p id="search-no-model" class="text-sm text-foreground/70">
            {dgettext(
              "showcase",
              "A search reads the facts already admitted. It calls no model."
            )}
          </p>
        </header>

        <section id="search-pick" class="space-y-2">
          <h3 class="font-heading">{dgettext("showcase", "Pick a filter")}</h3>
          <div class="flex flex-wrap gap-2">
            <.button
              :for={preset <- @presets}
              id={"pick-#{preset.id}"}
              type="button"
              size="sm"
              phx-click="pick"
              phx-value-id={preset.id}
            >
              {preset.words}
            </.button>
          </div>
        </section>

        <section id="search-words" class="space-y-2">
          <h3 class="font-heading">{dgettext("showcase", "Or say what you want")}</h3>
          <.form for={to_form(%{"words" => @words}, as: :words)} id="words-form" phx-submit="propose">
            <div class="flex flex-wrap items-end gap-2">
              <input
                id="words-input"
                name="words[words]"
                value={@words}
                class="min-w-[18rem] flex-1 rounded-base border-2 border-border bg-background p-2 text-sm"
              />
              <.button id="propose" type="submit" size="sm">
                {dgettext("showcase", "Propose a filter")}
              </.button>
            </div>
          </.form>
          <p :if={@model_mode == :recorded} class="text-sm text-foreground/70">
            {dgettext(
              "showcase",
              "Recorded mode: only the four searches above have a recorded translation."
            )}
          </p>
        </section>

        <section id="search-filter" class="space-y-2">
          <h3 class="font-heading">{dgettext("showcase", "The filter, in CQL2")}</h3>
          <p class="text-sm text-foreground/70">
            {dgettext(
              "showcase",
              "This is what runs, exactly as written here. Edit it first if you like."
            )}
          </p>
          <.form
            for={to_form(%{"text" => @text}, as: :search)}
            id="search-form"
            phx-change="edit"
            phx-submit="run"
          >
            <textarea
              id="filter-text"
              name="search[text]"
              rows="9"
              spellcheck="false"
              class="w-full rounded-base border-2 border-border bg-background p-2 font-mono text-sm"
            >{@text}</textarea>
            <.button id="run" type="submit" variant="primary" class="mt-2">
              {dgettext("showcase", "Approve and run")}
            </.button>
          </.form>
          <.status_message id="search-error" role="alert" show={@error != nil} kind={:error}>
            {@error}
          </.status_message>
        </section>

        <section :if={@result} id="search-result" class="space-y-3">
          <h3 class="font-heading">{dgettext("showcase", "Result")}</h3>
          <p :if={empty?(@result)} id="search-empty" class="text-sm font-medium">
            {dgettext(
              "showcase",
              "You can read none of the facts this search runs over, so there is nothing to show."
            )}
          </p>
          <div :if={not empty?(@result)} class="grid gap-3 md:grid-cols-3">
            <.group
              id="group-in"
              title={dgettext("showcase", "In")}
              blurb={dgettext("showcase", "The filter holds, on facts that are admitted.")}
              rows={@result.partitions.in}
              names={@names}
            />
            <.group
              id="group-out"
              title={dgettext("showcase", "Out")}
              blurb={dgettext("showcase", "The filter does not hold, on facts that are admitted.")}
              rows={@result.partitions.out}
              names={@names}
            />
            <.group
              id="group-unknown"
              title={dgettext("showcase", "Unknown")}
              blurb={dgettext("showcase", "The facts needed to decide are missing or expired.")}
              rows={@result.partitions.unknown}
              names={@names}
            />
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end
end
