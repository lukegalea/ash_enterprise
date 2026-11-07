defmodule AshEnterprise.Artifacts.Change do
  @moduledoc """
  One semantic change between two versions of an artifact.

    * `aspect`: what kind of thing changed, one of the differ's `aspects/0`
      (`:authority`, `:tools`, `:routing`, `:cases`).
    * `kind`: `:added`, `:removed` or `:changed`.
    * `subject`: the named thing within the aspect (a tool's target, a step's
      id, a case's id), or `nil` when the aspect is a single value.
    * `option`: for `:changed`, which property of the subject changed, or `nil`.
    * `from` / `to`: the old and new value, already put into words or plain data
      the page can print. A value the differ could not read is `:unread`.
  """

  @derive {Jason.Encoder, only: [:aspect, :kind, :subject, :option, :from, :to]}
  @enforce_keys [:aspect, :kind]
  defstruct [:aspect, :kind, :subject, :option, :from, :to]

  @type t :: %__MODULE__{
          aspect: atom(),
          kind: :added | :removed | :changed,
          subject: String.t() | nil,
          option: String.t() | nil,
          from: term(),
          to: term()
        }

  @doc """
  The changes between two maps of named subjects (`%{name => value}`) under
  `aspect`: added and removed names, and, for a name in both, each property
  (`option`) whose value differs. Values that are maps are compared property by
  property; any other value is compared whole.
  """
  @spec keyed(atom(), map(), map()) :: [t()]
  def keyed(aspect, old, new) do
    names = old |> Map.keys() |> Kernel.++(Map.keys(new)) |> Enum.uniq() |> Enum.sort()

    Enum.flat_map(names, fn name ->
      case {Map.fetch(old, name), Map.fetch(new, name)} do
        {:error, {:ok, value}} ->
          [%__MODULE__{aspect: aspect, kind: :added, subject: to_string(name), to: value}]

        {{:ok, value}, :error} ->
          [%__MODULE__{aspect: aspect, kind: :removed, subject: to_string(name), from: value}]

        {{:ok, same}, {:ok, same}} ->
          []

        {{:ok, from}, {:ok, to}} ->
          properties(aspect, to_string(name), from, to)
      end
    end)
  end

  @doc "A change of a single value under `aspect`, or none when it is equal."
  @spec value(atom(), term(), term(), String.t() | nil) :: [t()]
  def value(aspect, from, to, subject \\ nil)
  def value(_aspect, same, same, _subject), do: []

  def value(aspect, from, to, subject),
    do: [%__MODULE__{aspect: aspect, kind: :changed, subject: subject, from: from, to: to}]

  defp properties(aspect, name, %{} = from, %{} = to) do
    from
    |> Map.keys()
    |> Kernel.++(Map.keys(to))
    |> Enum.uniq()
    |> Enum.sort_by(&to_string/1)
    |> Enum.flat_map(fn option ->
      case {Map.get(from, option), Map.get(to, option)} do
        {same, same} ->
          []

        {old, new} ->
          [
            %__MODULE__{
              aspect: aspect,
              kind: :changed,
              subject: name,
              option: to_string(option),
              from: old,
              to: new
            }
          ]
      end
    end)
  end

  defp properties(aspect, name, from, to),
    do: [%__MODULE__{aspect: aspect, kind: :changed, subject: name, from: from, to: to}]
end
