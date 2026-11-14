defmodule Mix.Tasks.AshEnterprise.DataInventory do
  @shortdoc "Generate docs/data-inventory.json from the resource declarations"

  @moduledoc """
  Writes the data inventory and the egress register to `docs/data-inventory.json`.

      mix ash_enterprise.data_inventory           # rewrite the file
      mix ash_enterprise.data_inventory --check   # fail if the file is out of date

  The inventory is read from the declarations every resource in the configured
  domains was compiled with (`AshEnterprise.Governance.DataInventory`), so a
  resource added without regenerating the file makes `--check` fail, the way
  `mix ash.codegen --check` does for the schema. `--check` also fails while a
  personal-looking attribute is neither sensitive, sealed nor excepted with a
  reason.
  """

  use Mix.Task

  alias AshEnterprise.Governance.DataInventory

  @requirements ["app.config"]

  @target "docs/data-inventory.json"

  @impl Mix.Task
  def run(argv) do
    {opts, _rest} = OptionParser.parse!(argv, strict: [check: :boolean])
    Mix.Task.run("compile")

    document = DataInventory.build()
    content = render(document)

    case DataInventory.unclassified(document) do
      [] -> :ok
      unclassified -> fail_unclassified(unclassified)
    end

    cond do
      opts[:check] ->
        check(content)

      File.exists?(@target) and File.read!(@target) == content ->
        Mix.shell().info("#{@target} is current.")

      true ->
        File.write!(@target, content)
        Mix.shell().info("Wrote #{@target}.")
    end
  end

  @doc "The file's content for `document` (default: the one built from the compiled resources)."
  @spec render(map()) :: String.t()
  def render(document \\ DataInventory.build()), do: DataInventory.encode(document)

  @doc "The committed file's path, relative to the project root."
  @spec path() :: String.t()
  def path, do: @target

  defp check(content) do
    if File.exists?(@target) and File.read!(@target) == content do
      Mix.shell().info("#{@target} is current.")
    else
      Mix.shell().error("""

      #{@target} is out of date with the resource declarations.

      Run `mix ash_enterprise.data_inventory` and commit the result.
      """)

      exit({:shutdown, 1})
    end
  end

  defp fail_unclassified(unclassified) do
    lines = Enum.map_join(unclassified, "\n", &"  * #{&1["resource"]}.#{&1["attribute"]}")

    Mix.shell().error("""

    These attributes look like personal data and are neither `sensitive? true`, sealed
    (cloaked) nor listed with a reason in AshEnterprise.Governance.DataFlows.looks_personal_exceptions/0:

    #{lines}
    """)

    exit({:shutdown, 1})
  end
end
