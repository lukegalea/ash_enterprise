defmodule AshEnterprise.Canonical.Calculations.TaskLabel do
  @moduledoc """
  What a `Canonical.Task` says: the sealed `commitment` of a task that came
  from a source, rendered `[shredded]` once that source's erasure scope is
  shredded, else the `title` a person typed. Display-only.
  """

  use Ash.Resource.Calculation

  alias AshEnterprise.Erasure.Shredded

  @impl true
  def load(_query, _opts, _context), do: [:title, :commitment]

  @impl true
  def calculate(tasks, _opts, _context), do: {:ok, Enum.map(tasks, &label/1)}

  defp label(%{commitment: %Shredded{}}), do: Shredded.rendered()
  defp label(%{commitment: commitment}) when is_binary(commitment), do: commitment
  defp label(%{title: title}), do: title
end
