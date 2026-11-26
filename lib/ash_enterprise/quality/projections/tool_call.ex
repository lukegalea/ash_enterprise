defmodule AshEnterprise.Quality.Projections.ToolCall do
  @moduledoc """
  The `state_projection` of the pre-flight gate's questions
  (`AshEnterprise.Quality.ToolCall`): the tool, the command, the paths and
  the repository's kind, and nothing else.

  The state is four strings: `paths` joined by newlines, and an absent
  command or kind as `""`. File contents, the session, the working
  directory and the harness are left out: what the call does is in its
  command and paths, and a session or a directory name would make the same
  call two subjects.

  `shape/0` is part of each question's hash, so a change to what the model
  sees is a new question and `priv/judgments/lock.json` refuses it without
  a version bump.
  """

  @behaviour AshJudgments.Registry.StateProjection

  @shape %{
    "tool" => "string",
    "command" => "string",
    "paths" => "string",
    "repo_kind" => "string"
  }

  @impl AshJudgments.Registry.StateProjection
  def project(%{arguments: %{input: call}}, _context), do: state(call)
  def project(call, _context) when is_map(call), do: state(call)

  @impl AshJudgments.Registry.StateProjection
  def shape, do: @shape

  @doc """
  The state for a tool call: an `AshEnterprise.Quality.ToolCall`, or a map
  with its fields under atom or string keys.
  """
  @spec state(map()) :: %{String.t() => String.t()}
  def state(call) do
    %{
      "tool" => call |> field(:tool) |> string(),
      "command" => call |> field(:command) |> string(),
      "paths" => call |> field(:paths) |> List.wrap() |> Enum.join("\n"),
      "repo_kind" => call |> field(:repo_kind) |> string()
    }
  end

  defp field(call, key), do: Map.get(call, key, Map.get(call, Atom.to_string(key)))

  defp string(nil), do: ""
  defp string(value), do: to_string(value)
end
