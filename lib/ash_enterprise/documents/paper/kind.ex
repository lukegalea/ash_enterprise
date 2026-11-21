defmodule AshEnterprise.Documents.Paper.Kind do
  @moduledoc """
  A kind of document the host can issue: one module per kind, registered in
  the list the host application owns,

      config :ash_enterprise, AshEnterprise.Documents.Paper,
        kinds: [MyApp.Paper.CredentialLetter]

  (`AshEnterprise.Documents.Paper.kinds/0`). The paper machinery
  (`AshEnterprise.Documents.Paper.Actions.Issue`, the clause selection, the
  interview, drafts and impact) reads everything kind-specific through these
  callbacks, so it names no business domain of its own.

  | Callback | What it says |
  |---|---|
  | `key/0` | the kind's key, the `document_kind` a run records |
  | `schema/0` | the `AshPaper.Schema` the payload is built with |
  | `default_theme/0` | the theme name a first binding uses |
  | `clause_keys/0` | the clause keys the kind may carry, each with a `paper.clause.<key>` decision |
  | `decision_inputs/1` | the categorical inputs those decisions read, from the payload's typed facts |
  | `locale/1` | the locale the payload is built in, for the subject |
  | `requirement/0` | the `AshRules` module evaluated before a render (its bundle and fact schema, plus `ground_facts/1` and `subject/0`), or nil |
  | `source/2` | the map the payload is built from, read server-side as the actor |
  | `scope/1` | the scope an interview answer is recorded and read in (the organization is added) |
  | `valid_until/1` | until when an answer in that scope holds, or nil for no expiry |
  | `sealing_scope/2` | optional: the erasure scope of the person the document is about, read server-side as the actor |

  ## The subject

  `issue`, `draft` and `issue_draft` never take a caller's values. They take
  the kind and its **subject**: the arguments that say which of the kind's
  rows a document is about (a period, a record id), as a map with string or
  atom keys. `source/2` reads those rows itself, as the actor, through the
  actor's own policies, and returns the source map, or `{:error, reason}`
  when the subject is malformed or the actor reaches nothing to read. A draft
  records its subject (sealed, in its fingerprint), so `issue_draft` re-reads
  the same rows.

  ## Whose scope seals the run

  A run's `payload`, `facts` and `payload_hash_key` are sealed under an
  erasure scope. A kind whose documents are about a person other than the
  requester names that person's scope with the optional `sealing_scope/2`:
  given the subject, it reads the row that says whose scope it is, as the
  actor (as `source/2` does), and returns `{:ok, scope_id}` or
  `{:error, reason}`. The requester still owns the run; shredding the named
  scope is what erases what the document said
  (`AshEnterprise.Documents.Paper.SealingScope`). A kind that does not
  implement it is sealed under the requester's own scope. A shredded or
  unknown scope, or an error, refuses the issue: there is no fallback.

  `use AshEnterprise.Documents.Paper.Kind` gives the defaults a kind without
  clauses or requirement needs: no clause keys, no decision inputs, locale
  `:en`, no requirement, an empty scope and no expiry.
  """

  @typedoc "A kind's subject: the arguments naming the rows a document is about."
  @type subject :: map()

  @callback key() :: String.t()
  @callback schema() :: module()
  @callback default_theme() :: String.t()
  @callback clause_keys() :: [String.t()]
  @callback decision_inputs(AshPaper.Payload.t()) :: map()
  @callback locale(subject()) :: atom()
  @callback requirement() :: module() | nil
  @callback source(subject(), keyword()) :: {:ok, map()} | {:error, term()}
  @callback scope(AshPaper.Payload.t()) :: map()
  @callback valid_until(map()) :: DateTime.t() | nil
  @callback sealing_scope(subject(), keyword()) :: {:ok, Ecto.UUID.t()} | {:error, term()}

  @optional_callbacks sealing_scope: 2

  defmacro __using__(_opts) do
    quote do
      @behaviour AshEnterprise.Documents.Paper.Kind

      @impl AshEnterprise.Documents.Paper.Kind
      def clause_keys, do: []

      @impl AshEnterprise.Documents.Paper.Kind
      def decision_inputs(%AshPaper.Payload{}), do: %{}

      @impl AshEnterprise.Documents.Paper.Kind
      def locale(_subject), do: :en

      @impl AshEnterprise.Documents.Paper.Kind
      def requirement, do: nil

      @impl AshEnterprise.Documents.Paper.Kind
      def scope(%AshPaper.Payload{}), do: %{}

      @impl AshEnterprise.Documents.Paper.Kind
      def valid_until(_scope), do: nil

      defoverridable clause_keys: 0,
                     decision_inputs: 1,
                     locale: 1,
                     requirement: 0,
                     scope: 1,
                     valid_until: 1
    end
  end

  @doc """
  The value of `name` in a subject, whether its key is a string or an atom
  (a code interface passes atoms, a form strings).
  """
  @spec arg(subject(), atom()) :: term()
  def arg(subject, name) when is_map(subject) and is_atom(name),
    do: Map.get(subject, Atom.to_string(name), Map.get(subject, name))

  def arg(_subject, _name), do: nil
end
