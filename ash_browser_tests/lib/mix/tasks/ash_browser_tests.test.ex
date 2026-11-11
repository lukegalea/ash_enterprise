defmodule Mix.Tasks.AshBrowserTests.Test do
  @shortdoc "Builds assets, picks a free port and runs the browser tests"

  @moduledoc """
  Runs the browser tests the way a host's suite needs them, so the same command
  works on a shared machine.

      mix ash_browser_tests.test --assets "assets.build" test/e2e

  Options:

    * `--assets TASK` - a mix task that builds CSS and JS (repeatable), run in
      `MIX_ENV=dev`. Without the compiled Tailwind, elements a page hides are
      visible, and locators that assume they are hidden become ambiguous.
    * `--assets-env ENV` - the environment for those tasks. Default `dev`.
    * `--port PORT` - use this port rather than an unused one.

  Remaining arguments go to `mix test`.

  A free port is allocated and the suite runs as a child `mix test`, with `E2E=1`,
  `E2E_PORT`, and `PORT` set. Configuration reads environment variables when
  `mix` starts, so they must be set in a fresh process.

  Set `PORT` too because a host's `config/runtime.exs` often reads it in every
  environment and overrides `E2E_PORT` otherwise.
  """

  use Mix.Task

  @impl Mix.Task
  def run(args) do
    {opts, rest} =
      OptionParser.parse_head!(args,
        strict: [assets: :keep, assets_env: :string, port: :integer]
      )

    assets_env = Keyword.get(opts, :assets_env, "dev")

    for task <- Keyword.get_values(opts, :assets) do
      run_mix(task, [{"MIX_ENV", assets_env}])
    end

    port = Keyword.get_lazy(opts, :port, &AshBrowserTests.free_port/0)
    Mix.shell().info("browser tests on port #{port}")

    env = [
      {"MIX_ENV", "test"},
      {"E2E", "1"},
      {"E2E_PORT", to_string(port)},
      {"PORT", to_string(port)}
    ]

    run_mix("test " <> Enum.join(rest, " "), env)
  end

  defp run_mix(task, env) do
    {_output, status} =
      System.cmd("mix", String.split(task, " ", trim: true),
        env: env,
        into: IO.stream(:stdio, :line),
        stderr_to_stdout: true
      )

    if status != 0, do: Mix.raise("`mix #{task}` exited with status #{status}")
  end
end
