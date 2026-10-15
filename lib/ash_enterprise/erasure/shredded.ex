defmodule AshEnterprise.Erasure.Shredded do
  @moduledoc """
  What a sealed value reads as once its erasure scope has been shredded.

  Not `nil` — `nil` is a real value ("no location") and a reader must be able to
  tell "there was nothing" from "there was something and it is gone". Not a
  crash either: a shredded Slack scope must not take down every page that lists
  messages. And not a magic string, which a real message could contain.

  A struct, so code that needs to care can match on it
  (`AshEnterprise.Erasure.Shredded.shredded?/1`), and with `Jason.Encoder`,
  `String.Chars` and `Phoenix.HTML.Safe` implemented so that code which does
  not care — JSON APIs, string interpolation, HEEx templates — renders an
  explicit `[shredded]` rather than raising.

  It carries the scope id, which is structural (the row already names its
  scope), never content.
  """

  @derive {Inspect, only: [:erasure_scope_id]}
  defstruct [:erasure_scope_id]

  @type t :: %__MODULE__{erasure_scope_id: Ash.UUID.t()}

  @rendered "[shredded]"

  @doc "True for a value whose scope has been shredded."
  @spec shredded?(term()) :: boolean()
  def shredded?(%__MODULE__{}), do: true
  def shredded?(_value), do: false

  @doc "The text every renderer shows in place of shredded content."
  def rendered, do: @rendered

  defimpl String.Chars do
    def to_string(_shredded), do: AshEnterprise.Erasure.Shredded.rendered()
  end

  defimpl Phoenix.HTML.Safe do
    def to_iodata(_shredded), do: AshEnterprise.Erasure.Shredded.rendered()
  end

  defimpl Jason.Encoder do
    def encode(%{erasure_scope_id: scope_id}, opts) do
      Jason.Encode.map(%{"shredded" => true, "erasure_scope_id" => scope_id}, opts)
    end
  end
end
