defmodule AshEnterprise.Documents.Paper do
  @moduledoc """
  What this host can issue as a document (the façade over the kernel's
  axes): the kinds, the one layout, the themes.

  A kind is a module (`AshEnterprise.Documents.Paper.Kind`) in the list the
  host application owns:

      config :ash_enterprise, AshEnterprise.Documents.Paper, kinds: [MyApp.Paper.Letter]

  Adding a kind is a module in that list and its schema in
  `config :ash_paper, :schemas` (which `mix paper.lock` locks).

  `"maplestone"` is hand-authored from a real-shaped business letter: a Word
  template of a fictional property manager (synthetic content), exported to
  PDF the way such a company's own documents are, with every token measured from that
  PDF — fonts (Calibri and Cambria map to their metric-compatible Carlito and
  Caladea), size, margins, colours, line pitch baseline to baseline, paragraph
  gap, the accent rule and the table's rules and header. A theme is host code
  here; tenant-owned themes a person activates come later.

  Every theme names fonts the kernel vendors (`AshPaper.Fonts.families/0` —
  Carlito, Caladea, Liberation), so a render never reaches for a system
  font. Money in a schema carries its ISO currency code beside the amount,
  so no document ever prints a bare `$` or rounds.
  """

  alias AshEnterprise.Documents.Paper.Error, as: PaperError
  alias AshEnterprise.Documents.Paper.Letter
  alias AshEnterprise.Documents.PaperClause

  require Ash.Query

  @binding_purpose "paper.render"

  @decision_key_prefix "paper.clause."

  @theme_base %{version: 1, body_size: 11, margin_x: 72, margin_y: 72, paper: "us-letter"}

  @theme_tokens %{
    "carlito" => %{
      key: "ash-enterprise-carlito",
      body_font: "Carlito",
      heading_font: "Carlito",
      accent: "#1f3a5f"
    },
    "caladea" => %{
      key: "ash-enterprise-caladea",
      body_font: "Caladea",
      heading_font: "Caladea",
      accent: "#5a2d0c"
    },
    "maplestone" => %{
      key: "ash-enterprise-maplestone",
      body_font: "Carlito",
      heading_font: "Caladea",
      body_size: 11,
      margin_x: 65,
      margin_y: 54,
      paper: "us-letter",
      accent: "#0b5563",
      text_color: "#222222",
      muted_color: "#6b7280",
      heading_size: 16,
      line_spacing: 1.405,
      paragraph_spacing: 8,
      title_rule: 1.5,
      table_stroke: "#9fb8bb",
      table_header_fill: "#dcebec",
      table_header_text: "#0b5563"
    }
  }

  @layout Letter

  @max_pages 20
  @timeout_ms 30_000

  @typedoc "A theme name from `themes/0`."
  @type theme_name :: String.t()

  @doc """
  The kinds the host can issue, by key: the `AshEnterprise.Documents.Paper.Kind`
  modules listed in `config :ash_enterprise, AshEnterprise.Documents.Paper, :kinds`.
  """
  @spec kinds() :: %{String.t() => module()}
  def kinds do
    :ash_enterprise
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:kinds, [])
    |> Map.new(&{&1.key(), &1})
  end

  @doc "The kind module for `key`: `{:ok, module}` or `{:error, %PaperError{reason: {:unknown_kind, key}}}`."
  @spec kind(String.t()) :: {:ok, module()} | {:error, PaperError.t()}
  def kind(key) when is_binary(key) do
    case Map.fetch(kinds(), key) do
      {:ok, module} -> {:ok, module}
      :error -> {:error, PaperError.exception(reason: {:unknown_kind, key})}
    end
  end

  @doc """
  The clause keys `kind` may carry: each has a `paper.clause.<key>` decision
  and, when selected at issue, is pinned by the tenant's binding. A key `k`'s
  decision says whether the clause is in and why, and reads the inputs
  `decision_inputs/2` produces for the kind: adding a candidate key means
  adding both.
  """
  @spec clause_keys(String.t()) :: [String.t()]
  def clause_keys(kind) when is_binary(kind) do
    case kind(kind) do
      {:ok, module} -> module.clause_keys()
      {:error, _unknown} -> []
    end
  end

  @doc """
  The requirement `kind` is evaluated against before it renders (an `AshRules`
  module with `ground_facts/1` and `subject/0`), or nil when the kind has none
  (`AshEnterprise.Documents.Paper.Interview`).
  """
  @spec requirement(String.t()) :: module() | nil
  def requirement(kind) when is_binary(kind) do
    case kind(kind) do
      {:ok, module} -> module.requirement()
      {:error, _unknown} -> nil
    end
  end

  @doc "The DMN decision key that says whether clause key `key` is in, and why."
  @spec decision_key(String.t()) :: String.t()
  def decision_key(key), do: @decision_key_prefix <> key

  @doc """
  The categorical inputs the kind's clause tables read, from the payload's
  typed facts (the kind's `decision_inputs/1`). A kind with no clause produces
  no inputs, so any table that declares one is refused at issue
  (`AshEnterprise.Documents.Paper.Clauses`), never fed a null.
  """
  @spec decision_inputs(String.t(), AshPaper.Payload.t()) :: map()
  def decision_inputs(kind, %AshPaper.Payload{} = payload) when is_binary(kind) do
    case kind(kind) do
      {:ok, module} -> module.decision_inputs(payload)
      {:error, _unknown} -> %{}
    end
  end

  @doc "The host's one layout."
  @spec layout() :: module()
  def layout, do: @layout

  @doc "The purpose a paper binding is bound under."
  @spec binding_purpose() :: String.t()
  def binding_purpose, do: @binding_purpose

  @doc """
  The selector string a binding for `kind` is bound under: the canonical
  JSON the `AshPlanning.Fragment.Binding` stores (`selector/2`).
  """
  @spec binding_selector(String.t()) :: String.t()
  def binding_selector(kind),
    do: AshPlanning.Fragment.Binding.selector(kind, @binding_purpose)

  @doc """
  What `kind` is issued with by default: `{:ok, schema, layout, theme}`, or
  `{:error, %PaperError{reason: {:unknown_kind, kind}}}`. The theme is the
  kind's default; `issue` renders the theme the tenant's binding pins
  (`AshEnterprise.Documents.Paper.Actions.Issue.pinned_theme/3`).
  """
  @spec definition(String.t()) ::
          {:ok, module(), module(), AshPaper.Theme.t()} | {:error, PaperError.t()}
  def definition(kind) when is_binary(kind) do
    with {:ok, module} <- kind(kind) do
      {:ok, module.schema(), @layout, theme(module.default_theme())}
    end
  end

  @doc """
  The theme names: `"carlito"`, `"caladea"` and the hand-authored `"maplestone"`.
  """
  @spec themes() :: [theme_name()]
  def themes, do: Map.keys(@theme_tokens)

  @doc """
  The theme a binding pins, by the kernel key the binding stores (not a
  name): the theme struct, or nil when no host theme has that key.
  """
  @spec theme_by_key(String.t() | nil) :: AshPaper.Theme.t() | nil
  def theme_by_key(key) when is_binary(key) do
    {name, _tokens} =
      Enum.find(@theme_tokens, fn {_name, tokens} -> tokens.key == key end) || {nil, nil}

    name && theme(name)
  end

  @doc "The named theme: `{:ok, theme}` or `{:error, {:unknown_theme, name}}`."
  @spec theme(theme_name()) :: AshPaper.Theme.t() | no_return()
  def theme(name)

  def theme(name) when is_binary(name) do
    {:ok, theme} = AshPaper.Theme.new(Map.merge(@theme_base, Map.fetch!(@theme_tokens, name)))
    theme
  end

  @doc """
  The definitions `AshPaper.Binding.selection/4` stores for a kind's
  schema, layout and theme, plus the admitted wording: the latest `:admitted`
  `PaperClause` version for each `(key, locale)` the kind may carry, every
  locale, as kernel clauses. A version admitted after this was bound makes the
  binding stale until it is rebound
  (`AshEnterprise.Documents.Paper.Clauses` checks that at issue).
  """
  @spec selection(module(), module() | AshPaper.Layout.t(), AshPaper.Theme.t(), Ash.UUID.t()) ::
          [map()]
  def selection(schema, layout, theme, tenant) do
    clauses = admitted_clauses(schema, tenant)
    AshPaper.Binding.selection(schema, layout, theme, clauses)
  end

  defp admitted_clauses(schema, tenant) do
    keys = clause_keys(to_string(AshPaper.Schema.key(schema)))

    if keys == [] do
      []
    else
      latest_admitted_clauses(keys, tenant)
      |> Enum.map(&PaperClause.to_kernel/1)
    end
  end

  # The highest `:admitted` version per `(key, locale)` among `keys`: the
  # versions a binding pins, one per wording and locale. Read without
  # authorization on purpose — the caller of `selection` was already authorized
  # to bind, and this builds the value the binding stores.
  @doc false
  def latest_admitted_clauses(keys, tenant) do
    PaperClause
    |> Ash.Query.filter(status == :admitted and key in ^keys)
    |> Ash.Query.sort(key: :asc, locale: :asc, version: :desc)
    |> Ash.read!(tenant: tenant, authorize?: false)
    |> Enum.uniq_by(&{&1.key, &1.locale})
  end

  @doc "The render limits every issue runs under: `#{@max_pages}` pages, #{@timeout_ms} ms."
  @spec limits() :: keyword()
  def limits, do: [max_pages: @max_pages, timeout_ms: @timeout_ms]
end
