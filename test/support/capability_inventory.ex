defmodule AshEnterprise.Test.CapabilityInventory do
  @moduledoc """
  Reads `docs/capabilities.json`, the capability inventory, and resolves what
  it points at: the test files its rows cite and the `mix.lock` entries its
  pins name.

  The inventory is data rather than code so that it can be read, diffed and
  rendered without compiling anything, the same as `docs/roadmap.json`. This
  module only reads it; `test/ash_enterprise/capability_inventory_test.exs`
  decides whether what it says is true.
  """

  @root Path.expand("../..", __DIR__)
  @source Path.join(@root, "docs/capabilities.json")

  @statuses ~w(existing partial missing refused)

  @doc "The statuses a row may carry, weakest claim last."
  def statuses, do: @statuses

  @doc "The decoded inventory."
  def load!, do: @source |> File.read!() |> Jason.decode!()

  @doc "The path of the inventory, relative to the project root."
  def source, do: Path.relative_to(@source, @root)

  @doc """
  The absolute path a test reference names: a file in this project, or, with
  `"dep"`, a file in that dependency's checkout.
  """
  def test_path(%{"dep" => dep, "file" => file}) do
    case Enum.find(Mix.Project.deps_paths(), fn {name, _dir} -> Atom.to_string(name) == dep end) do
      {_name, dir} -> {:ok, Path.join(dir, file)}
      nil -> {:error, "#{dep} is not a dependency of this project"}
    end
  end

  def test_path(%{"file" => file}), do: {:ok, Path.join(@root, file)}

  @doc """
  What `mix.lock` pins each dependency to: the version of a Hex package, the
  commit of a git dependency.
  """
  def locked do
    # Parsed quietly: mix.lock quotes every key, which the parser would warn
    # about once per dependency.
    {lock, _binding} =
      @root
      |> Path.join("mix.lock")
      |> File.read!()
      |> Code.string_to_quoted!(emit_warnings: false)
      |> Code.eval_quoted()

    Map.new(lock, fn
      {name, {:hex, _package, version, _hash, _managers, _deps, _repo, _outer}} ->
        {Atom.to_string(name), {:hex, version}}

      {name, {:git, _url, sha, _opts}} ->
        {Atom.to_string(name), {:git, sha}}

      {name, other} ->
        {Atom.to_string(name), {:other, other}}
    end)
  end
end
