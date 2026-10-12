defmodule AshEnterpriseWeb.CoreComponents do
  @moduledoc """
  Provides core UI components.

  At first glance, this module may seem daunting, but its goal is to provide
  core building blocks for your application, such as tables, forms, and
  inputs. The components consist mostly of markup and are well-documented
  with doc strings and declarative assigns. You may customize and style
  them in any way you want, based on your application growth and needs.

  The foundation for styling is Tailwind CSS, carrying a neobrutalism design
  system whose tokens live in `assets/css/neobrutalism.css`: one ink colour for
  text, borders, shadows and focus rings; 2px borders; a hard 4px offset
  shadow; 5px radii; DM Sans; and a lift/press motion pair (hover grows the
  shadow, active presses into it). Dark is the default theme and light is one
  toggle away; components use token utilities only (`bg-secondary-background`,
  `text-foreground`, `border-border`, `shadow-shadow`), never literal colours,
  so both themes come for free. Vivid fills (`bg-main`, `bg-yellow`, ...) carry
  `text-on-vivid`, which stays black in both themes. See
  `docs/adr/0050-neobrutalism-design-system.md`. Useful references:

    * [neobrutalism.dev](https://www.neobrutalism.dev) - the design system
      the token sheet implements.

    * [Tailwind CSS](https://tailwindcss.com) - the foundational framework
      we build on. You will use it for layout, sizing, flexbox, grid, and
      spacing.

    * [Heroicons](https://heroicons.com) - see `icon/1` for usage.

    * [Phoenix.Component](https://phoenix-live-view.hexdocs.pm/Phoenix.Component.html) -
      the component system used by Phoenix. Some components, such as `<.link>`
      and `<.form>`, are defined there.

  """
  use Phoenix.Component
  use Gettext, backend: AshEnterpriseWeb.Gettext

  alias Phoenix.LiveView.JS

  @doc """
  Renders flash notices.

  ## Examples

      <.flash kind={:info} flash={@flash} />
      <.flash
        id="welcome-back"
        kind={:info}
        phx-mounted={show("#welcome-back") |> JS.remove_attribute("hidden")}
        hidden
      >
        Welcome Back!
      </.flash>
  """
  attr :id, :string, doc: "the optional id of flash container"
  attr :flash, :map, default: %{}, doc: "the map of flash messages to display"
  attr :title, :string, default: nil
  attr :kind, :atom, values: [:info, :error], doc: "used for styling and flash lookup"
  attr :rest, :global, doc: "the arbitrary HTML attributes to add to the flash container"

  slot :inner_block, doc: "the optional inner block that renders the flash message"

  def flash(assigns) do
    assigns = assign_new(assigns, :id, fn -> "flash-#{assigns.kind}" end)

    ~H"""
    <div
      :if={msg = render_slot(@inner_block) || Phoenix.Flash.get(@flash, @kind)}
      id={@id}
      phx-click={JS.push("lv:clear-flash", value: %{key: @kind}) |> hide("##{@id}")}
      role="alert"
      class="fixed top-4 right-4 z-50"
      {@rest}
    >
      <%!-- A banner with an icon chip: a saturated square carrying the icon, so
           info (blue chip) and error (red chip) are told apart before a word
           is read. --%>
      <div class={[
        "relative grid w-80 max-w-80 grid-cols-[2rem_1fr_auto] items-start gap-3 rounded-base border-2 border-border bg-secondary-background px-4 py-3 text-sm text-wrap text-foreground shadow-shadow sm:w-96 sm:max-w-96"
      ]}>
        <span class={[
          "grid size-8 place-items-center rounded-base border-2 border-border text-on-vivid",
          @kind == :info && "bg-main",
          @kind == :error && "bg-red"
        ]}>
          <.icon :if={@kind == :info} name="hero-information-circle" class="size-5" />
          <.icon :if={@kind == :error} name="hero-exclamation-circle" class="size-5" />
        </span>
        <div class="min-w-0">
          <p :if={@title} class="font-heading">{@title}</p>
          <p>{msg}</p>
        </div>
        <button type="button" class="group self-start cursor-pointer" aria-label={gettext("close")}>
          <.icon name="hero-x-mark" class="size-5 opacity-60 group-hover:opacity-100" />
        </button>
      </div>
    </div>
    """
  end

  @doc """
  Renders a button with navigation support.

  The motion pair: hovering grows the hard shadow in place (the button reads
  as floating higher without moving), pressing nudges it down into a 2px
  shadow. `ghost` is the quiet variant for dense rows and toolbars: no fill
  or shadow at rest, the border and shadow arrive on hover.

  ## Examples

      <.button>Send!</.button>
      <.button phx-click="go" variant="primary">Send!</.button>
      <.button navigate={~p"/"} variant="accent" size="sm">Home</.button>
  """
  attr :rest, :global, include: ~w(href navigate patch method download name value disabled type)
  attr :class, :any, default: nil, doc: "extra classes, appended to the variant's"
  attr :variant, :string, values: ~w(primary accent neutral ghost), default: "neutral"
  attr :size, :string, values: ~w(xs sm md), default: "md"
  slot :inner_block, required: true

  def button(%{rest: rest} = assigns) do
    assigns =
      assign(assigns, :class, [button_class(assigns.variant, assigns.size), assigns.class])

    if rest[:href] || rest[:navigate] || rest[:patch] do
      ~H"""
      <.link class={@class} {@rest}>
        {render_slot(@inner_block)}
      </.link>
      """
    else
      ~H"""
      <button class={@class} {@rest}>
        {render_slot(@inner_block)}
      </button>
      """
    end
  end

  @doc """
  The class list behind `button/1`, for elements that must look like a button
  but cannot be one (a `<summary>`, a link rendered by a dependency).

  Static strings only: Tailwind finds classes by scanning source text, so a
  class assembled at runtime is never generated.
  """
  def button_class(variant \\ "neutral", size \\ "md") do
    base =
      "inline-flex items-center justify-center gap-2 whitespace-nowrap rounded-base border-2 font-base transition-all cursor-pointer focus-visible:outline-hidden focus-visible:ring-2 focus-visible:ring-ring focus-visible:ring-offset-2 focus-visible:ring-offset-background disabled:pointer-events-none disabled:opacity-50 active:translate-x-0.5 active:translate-y-0.5 active:shadow-press"

    sizes = %{
      "xs" => "h-7 px-2 text-xs",
      "sm" => "h-8 px-3 text-sm",
      "md" => "h-10 px-4 text-sm"
    }

    variants = %{
      "primary" => "border-border bg-main text-main-foreground shadow-shadow hover:shadow-lift",
      "accent" => "border-border bg-yellow text-on-vivid shadow-shadow hover:shadow-lift",
      "neutral" =>
        "border-border bg-secondary-background text-foreground shadow-shadow hover:shadow-lift",
      "ghost" =>
        "border-transparent bg-transparent text-foreground hover:border-border hover:bg-secondary-background hover:shadow-shadow"
    }

    [base, Map.fetch!(sizes, size), Map.fetch!(variants, variant)]
  end

  @doc """
  Renders a sticker-style badge: a small tag with the system border.

  A `tone` fills it with a palette colour, always with black ink. Without a
  tone it is the quiet surface badge. The status vocabulary used across the
  app is:

      success / published / live     green
      warning / needs attention      yellow
      danger / failed                red
      info / in progress             main (blue)
      draft / inert                  neutral

  Pass `sticker` for the peel-and-stick look: hard shadow plus a halo in the
  surface colour that keeps it readable over patterned backgrounds.

  ## Examples

      <.badge tone="green">Published</.badge>
      <.badge>v3</.badge>
  """
  attr :tone, :string,
    values: ~w(neutral main yellow pink green orange violet cyan red) ++ [nil],
    default: nil

  attr :sticker, :boolean, default: false
  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def badge(assigns) do
    ~H"""
    <span
      class={[
        "inline-flex w-fit items-center gap-1.5 rounded-base border-2 border-border px-2 py-0.5 text-xs font-base whitespace-nowrap",
        badge_fill(@tone),
        @sticker && "shadow-shadow ring-4 ring-secondary-background",
        @class
      ]}
      {@rest}
    >
      {render_slot(@inner_block)}
    </span>
    """
  end

  defp badge_fill(nil), do: "bg-secondary-background text-foreground"

  defp badge_fill(tone) do
    Map.fetch!(
      %{
        "neutral" => "bg-neutral text-on-vivid",
        "main" => "bg-main text-on-vivid",
        "yellow" => "bg-yellow text-on-vivid",
        "pink" => "bg-pink text-on-vivid",
        "green" => "bg-green text-on-vivid",
        "orange" => "bg-orange text-on-vivid",
        "violet" => "bg-violet text-on-vivid",
        "cyan" => "bg-cyan text-on-vivid",
        "red" => "bg-red text-on-vivid"
      },
      tone
    )
  end

  @doc """
  Renders a card: raised surface, 2px border, hard shadow, and an optional
  `accent`.

  The accent does two things: a dotted strip of the colour across the top,
  and a hover lift in the colour instead of the ink. The border and the
  resting shadow stay ink, so the palette stays an accent rather than a
  wallpaper.

  ## Examples

      <.card accent="violet">
        <h3 class="font-heading">Process designer</h3>
        <p>Draw the visit process.</p>
      </.card>
  """
  attr :accent, :string,
    values: ~w(main yellow pink green orange violet cyan red) ++ [nil],
    default: nil

  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def card(assigns) do
    # Static maps, never interpolated class names, so Tailwind's scanner sees
    # every class this component can emit.
    strip_fills = %{
      "main" => "bg-main",
      "yellow" => "bg-yellow",
      "pink" => "bg-pink",
      "green" => "bg-green",
      "orange" => "bg-orange",
      "violet" => "bg-violet",
      "cyan" => "bg-cyan",
      "red" => "bg-red"
    }

    lift_shadows = %{
      "main" => "hover:shadow-main",
      "yellow" => "hover:shadow-yellow",
      "pink" => "hover:shadow-pink",
      "green" => "hover:shadow-green",
      "orange" => "hover:shadow-orange",
      "violet" => "hover:shadow-violet",
      "cyan" => "hover:shadow-cyan",
      "red" => "hover:shadow-red"
    }

    assigns =
      assigns
      |> assign(:strip_fill, assigns.accent && strip_fills[assigns.accent])
      |> assign(:lift, assigns.accent && lift_shadows[assigns.accent])

    ~H"""
    <div
      class={[
        "flex flex-col gap-3 rounded-base border-2 border-border bg-secondary-background p-5 font-base text-foreground shadow-shadow transition-shadow",
        @lift,
        @class
      ]}
      {@rest}
    >
      <span
        :if={@strip_fill}
        aria-hidden="true"
        class={[
          "bg-dots -mx-5 -mt-5 mb-1 h-5 rounded-t-[3px] border-b-2 border-border text-on-vivid/25",
          @strip_fill
        ]}
      />
      {render_slot(@inner_block)}
    </div>
    """
  end

  @doc """
  Renders a callout: an inline status block for a result, an error or a
  warning, with an icon chip in the kind's colour.

  ## Examples

      <.callout kind={:error} role="alert">Something went wrong.</.callout>
  """
  attr :kind, :atom, values: [:info, :success, :warning, :error], default: :info
  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def callout(assigns) do
    ~H"""
    <div
      class={[
        "flex items-start gap-3 rounded-base border-2 border-border bg-secondary-background px-4 py-3 text-sm text-foreground shadow-shadow",
        @class
      ]}
      {@rest}
    >
      <span class={[
        "grid size-7 shrink-0 place-items-center rounded-base border-2 border-border text-on-vivid",
        @kind == :info && "bg-main",
        @kind == :success && "bg-green",
        @kind == :warning && "bg-yellow",
        @kind == :error && "bg-red"
      ]}>
        <.icon :if={@kind == :info} name="hero-information-circle-micro" class="size-4" />
        <.icon :if={@kind == :success} name="hero-check-micro" class="size-4" />
        <.icon :if={@kind == :warning} name="hero-exclamation-triangle-micro" class="size-4" />
        <.icon :if={@kind == :error} name="hero-exclamation-circle-micro" class="size-4" />
      </span>
      <div class="min-w-0 flex-1 self-center">{render_slot(@inner_block)}</div>
    </div>
    """
  end

  @doc """
  Renders an input with label and error messages.

  A `Phoenix.HTML.FormField` may be passed as argument,
  which is used to retrieve the input name, id, and values.
  Otherwise all attributes may be passed explicitly.

  ## Types

  This function accepts all HTML input types, considering that:

    * You may also set `type="select"` to render a `<select>` tag

    * `type="checkbox"` is used exclusively to render boolean values

    * For live file uploads, see `Phoenix.Component.live_file_input/1`

  See https://developer.mozilla.org/en-US/docs/Web/HTML/Element/input
  for more information. Unsupported types, such as radio, are best
  written directly in your templates.

  ## Examples

  ```heex
  <.input field={@form[:email]} type="email" />
  <.input name="my-input" errors={["oh no!"]} />
  ```

  ## Select type

  When using `type="select"`, you must pass the `options` and optionally
  a `value` to mark which option should be preselected.

  ```heex
  <.input field={@form[:user_type]} type="select" options={["Admin": "admin", "User": "user"]} />
  ```

  For more information on what kind of data can be passed to `options` see
  [`options_for_select`](https://phoenix-html.hexdocs.pm/Phoenix.HTML.Form.html#options_for_select/2).
  """
  attr :id, :any, default: nil
  attr :name, :any
  attr :label, :string, default: nil
  attr :value, :any

  attr :type, :string,
    default: "text",
    values: ~w(checkbox color date datetime-local email file month number password
               search select tel text textarea time url week hidden)

  attr :field, Phoenix.HTML.FormField,
    doc: "a form field struct retrieved from the form, for example: @form[:email]"

  attr :errors, :list, default: []
  attr :checked, :boolean, doc: "the checked flag for checkbox inputs"
  attr :prompt, :string, default: nil, doc: "the prompt for select inputs"
  attr :options, :list, doc: "the options to pass to Phoenix.HTML.Form.options_for_select/2"
  attr :multiple, :boolean, default: false, doc: "the multiple flag for select inputs"
  attr :class, :any, default: nil, doc: "the input class to use over defaults"
  attr :error_class, :any, default: nil, doc: "the input error class to use over defaults"

  attr :rest, :global,
    include: ~w(accept autocomplete capture cols disabled form list max maxlength min minlength
                multiple pattern placeholder readonly required rows size step)

  def input(%{field: %Phoenix.HTML.FormField{} = field} = assigns) do
    errors = if Phoenix.Component.used_input?(field), do: field.errors, else: []

    assigns
    |> assign(field: nil, id: assigns.id || field.id)
    |> assign(:errors, Enum.map(errors, &translate_error(&1)))
    |> assign_new(:name, fn -> if assigns.multiple, do: field.name <> "[]", else: field.name end)
    |> assign_new(:value, fn -> field.value end)
    |> input()
  end

  def input(%{type: "hidden"} = assigns) do
    ~H"""
    <input type="hidden" id={@id} name={@name} value={@value} {@rest} />
    """
  end

  def input(%{type: "checkbox"} = assigns) do
    assigns =
      assign_new(assigns, :checked, fn ->
        Phoenix.HTML.Form.normalize_value("checkbox", assigns[:value])
      end)

    ~H"""
    <div class="mb-4">
      <label for={@id} class="flex items-center gap-2">
        <input
          type="hidden"
          name={@name}
          value="false"
          disabled={@rest[:disabled]}
          form={@rest[:form]}
        />
        <input
          type="checkbox"
          id={@id}
          name={@name}
          value="true"
          checked={@checked}
          class={@class || "size-5 accent-main"}
          {@rest}
        /><span class="text-sm">{@label}</span>
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(%{type: "select"} = assigns) do
    ~H"""
    <div class="mb-4">
      <label for={@id}>
        <span :if={@label} class="mb-1 block text-sm font-heading">{@label}</span>
        <select
          id={@id}
          name={@name}
          class={[
            @class ||
              "h-10 w-full rounded-base border-2 border-border bg-secondary-background px-3 py-2 text-sm font-base text-foreground placeholder:text-foreground/60 focus-visible:outline-hidden focus-visible:ring-2 focus-visible:ring-ring focus-visible:ring-offset-2 focus-visible:ring-offset-background",
            @errors != [] && (@error_class || "border-error ring-2 ring-error")
          ]}
          multiple={@multiple}
          {@rest}
        >
          <option :if={@prompt} value="">{@prompt}</option>
          {Phoenix.HTML.Form.options_for_select(@options, @value)}
        </select>
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(%{type: "textarea"} = assigns) do
    ~H"""
    <div class="mb-4">
      <label for={@id}>
        <span :if={@label} class="mb-1 block text-sm font-heading">{@label}</span>
        <textarea
          id={@id}
          name={@name}
          class={[
            @class ||
              "min-h-20 w-full rounded-base border-2 border-border bg-secondary-background px-3 py-2 text-sm font-base text-foreground placeholder:text-foreground/60 focus-visible:outline-hidden focus-visible:ring-2 focus-visible:ring-ring focus-visible:ring-offset-2 focus-visible:ring-offset-background",
            @errors != [] && (@error_class || "border-error ring-2 ring-error")
          ]}
          {@rest}
        >{Phoenix.HTML.Form.normalize_value("textarea", @value)}</textarea>
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  # All other inputs text, datetime-local, url, password, etc. are handled here...
  def input(assigns) do
    ~H"""
    <div class="mb-4">
      <label for={@id}>
        <span :if={@label} class="mb-1 block text-sm font-heading">{@label}</span>
        <input
          type={@type}
          name={@name}
          id={@id}
          value={Phoenix.HTML.Form.normalize_value(@type, @value)}
          class={[
            @class ||
              "h-10 w-full rounded-base border-2 border-border bg-secondary-background px-3 py-2 text-sm font-base text-foreground placeholder:text-foreground/60 focus-visible:outline-hidden focus-visible:ring-2 focus-visible:ring-ring focus-visible:ring-offset-2 focus-visible:ring-offset-background",
            @errors != [] && (@error_class || "border-error ring-2 ring-error")
          ]}
          {@rest}
        />
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  # Helper used by inputs to generate form errors
  defp error(assigns) do
    ~H"""
    <p class="mt-1.5 flex gap-2 items-center text-sm text-error">
      <.icon name="hero-exclamation-circle" class="size-5" />
      {render_slot(@inner_block)}
    </p>
    """
  end

  @doc """
  Renders a header with title.
  """
  slot :inner_block, required: true
  slot :subtitle
  slot :actions

  def header(assigns) do
    ~H"""
    <header class={[@actions != [] && "flex items-center justify-between gap-6", "pb-4"]}>
      <div>
        <h1 class="text-lg font-heading leading-8">
          {render_slot(@inner_block)}
        </h1>
        <p :if={@subtitle != []} class="text-sm text-foreground/70">
          {render_slot(@subtitle)}
        </p>
      </div>
      <div class="flex-none">{render_slot(@actions)}</div>
    </header>
    """
  end

  @doc """
  Renders a table with generic styling.

  ## Examples

      <.table id="users" rows={@users}>
        <:col :let={user} label="id">{user.id}</:col>
        <:col :let={user} label="username">{user.username}</:col>
      </.table>
  """
  attr :id, :string, required: true
  attr :rows, :list, required: true
  attr :row_id, :any, default: nil, doc: "the function for generating the row id"
  attr :row_click, :any, default: nil, doc: "the function for handling phx-click on each row"

  attr :row_item, :any,
    default: &Function.identity/1,
    doc: "the function for mapping each row before calling the :col and :action slots"

  slot :col, required: true do
    attr :label, :string
  end

  slot :action, doc: "the slot for showing user actions in the last table column"

  def table(assigns) do
    assigns =
      with %{rows: %Phoenix.LiveView.LiveStream{}} <- assigns do
        assign(assigns, row_id: assigns.row_id || fn {id, _item} -> id end)
      end

    ~H"""
    <div class="overflow-auto rounded-base border-2 border-border shadow-shadow">
      <table class={table_class()}>
        <thead>
          <tr>
            <th :for={col <- @col}>{col[:label]}</th>
            <th :if={@action != []}>
              <span class="sr-only">{gettext("Actions")}</span>
            </th>
          </tr>
        </thead>
        <tbody id={@id} phx-update={is_struct(@rows, Phoenix.LiveView.LiveStream) && "stream"}>
          <tr :for={row <- @rows} id={@row_id && @row_id.(row)}>
            <td
              :for={col <- @col}
              phx-click={@row_click && @row_click.(row)}
              class={@row_click && "hover:cursor-pointer"}
            >
              {render_slot(col, @row_item.(row))}
            </td>
            <td :if={@action != []} class="w-0 font-heading">
              <div class="flex gap-4">
                <%= for action <- @action do %>
                  {render_slot(action, @row_item.(row))}
                <% end %>
              </div>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  @doc """
  The class list for a data table: ruled rows on the raised surface, a heavy
  heading row on the page colour. For hand-written `<table>`s that cannot use
  `table/1` (their rows are not a simple column list); wrap them in the same
  bordered `overflow-auto` frame `table/1` uses.

  Child selectors, not per-cell classes, so a template only names the table.
  """
  def table_class do
    "w-full bg-secondary-background text-sm text-foreground [&_thead_tr]:border-b-2 [&_thead_tr]:border-border [&_thead]:bg-background [&_th]:h-11 [&_th]:px-4 [&_th]:text-left [&_th]:font-heading [&_td]:px-4 [&_td]:py-2.5 [&_tbody_tr]:border-b-2 [&_tbody_tr]:border-border [&_tbody_tr:last-child]:border-b-0 [&_tbody_tr]:transition-colors [&_tbody_tr:hover]:bg-main/10"
  end

  @doc """
  Renders a data list.

  ## Examples

      <.list>
        <:item title="Title">{@post.title}</:item>
        <:item title="Views">{@post.views}</:item>
      </.list>
  """
  slot :item, required: true do
    attr :title, :string, required: true
  end

  def list(assigns) do
    ~H"""
    <ul class="rounded-base border-2 border-border bg-secondary-background font-base shadow-shadow">
      <li :for={item <- @item} class="border-b-2 border-border px-4 py-3 last:border-b-0">
        <div class="flex flex-col gap-1">
          <div class="font-heading">{item.title}</div>
          <div>{render_slot(item)}</div>
        </div>
      </li>
    </ul>
    """
  end

  @doc """
  Renders a [Heroicon](https://heroicons.com).

  Heroicons come in three styles – outline, solid, and mini.
  By default, the outline style is used, but solid and mini may
  be applied by using the `-solid` and `-mini` suffix.

  You can customize the size and colors of the icons by setting
  width, height, and background color classes.

  Icons are extracted from the `deps/heroicons` directory and bundled within
  your compiled app.css by the plugin in `assets/vendor/heroicons.js`.

  ## Examples

      <.icon name="hero-x-mark" />
      <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
  """
  attr :name, :string, required: true
  attr :class, :any, default: "size-4"

  def icon(%{name: "hero-" <> _} = assigns) do
    ~H"""
    <span class={[@name, @class]} />
    """
  end

  ## JS Commands

  def show(js \\ %JS{}, selector) do
    JS.show(js,
      to: selector,
      time: 300,
      transition:
        {"transition-all ease-out duration-300",
         "opacity-0 translate-y-4 sm:translate-y-0 sm:scale-95",
         "opacity-100 translate-y-0 sm:scale-100"}
    )
  end

  def hide(js \\ %JS{}, selector) do
    JS.hide(js,
      to: selector,
      time: 200,
      transition:
        {"transition-all ease-in duration-200", "opacity-100 translate-y-0 sm:scale-100",
         "opacity-0 translate-y-4 sm:translate-y-0 sm:scale-95"}
    )
  end

  @doc """
  Translates an error message using gettext.
  """
  def translate_error({msg, opts}) do
    # When using gettext, we typically pass the strings we want
    # to translate as a static argument:
    #
    #     # Translate the number of files with plural rules
    #     dngettext("errors", "1 file", "%{count} files", count)
    #
    # However the error messages in our forms and APIs are generated
    # dynamically, so we need to translate them by calling Gettext
    # with our gettext backend as first argument. Translations are
    # available in the errors.po file (as we use the "errors" domain).
    if count = opts[:count] do
      Gettext.dngettext(AshEnterpriseWeb.Gettext, "errors", msg, msg, count, opts)
    else
      Gettext.dgettext(AshEnterpriseWeb.Gettext, "errors", msg, opts)
    end
  end

  @doc """
  Translates the errors for a field from a keyword list of errors.
  """
  def translate_errors(errors, field) when is_list(errors) do
    for {^field, {msg, opts}} <- errors, do: translate_error({msg, opts})
  end
end
