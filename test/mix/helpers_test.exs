defmodule AshEnterprise.Mix.HelpersTest do
  @moduledoc """
  `LOG_LEVEL` reaches an `app.config` mix task's Logger: `config/runtime.exs`
  turns it into `config :logger, level:`, and the shared boot applies that to
  the Logger the VM already started (it reads its level only at start).
  """

  # Logger's level and the :logger env are global.
  use ExUnit.Case, async: false

  alias AshEnterprise.Mix.Helpers

  setup do
    level = Logger.level()
    env = Application.fetch_env(:logger, :level)
    log_level = System.get_env("LOG_LEVEL")

    on_exit(fn ->
      case env do
        {:ok, value} -> Application.put_env(:logger, :level, value)
        :error -> Application.delete_env(:logger, :level)
      end

      if log_level,
        do: System.put_env("LOG_LEVEL", log_level),
        else: System.delete_env("LOG_LEVEL")

      Logger.configure(level: level)
    end)
  end

  test "LOG_LEVEL in runtime.exs reaches the running Logger through boot_repo" do
    System.put_env("LOG_LEVEL", "info")
    config = Config.Reader.read!("config/runtime.exs", env: :test, imports: :disabled)
    assert get_in(config, [:logger, :level]) == :info

    # The Logger as the VM started it, then what `app.config` does with the
    # file: the environment, not the Logger. (In that order:
    # `Logger.configure/1` writes the environment too.)
    Logger.configure(level: :debug)
    Application.put_env(:logger, :level, :info)

    assert :ok = Helpers.boot_repo()
    assert Logger.level() == :info
  end

  # A task under `app.config` starts no application of the project's, Oban's own
  # included, so its registry is not running when `boot_oban_inserts/0` starts the
  # inserting-only instance. This node runs the whole application and cannot show that;
  # a second BEAM (`:peer`) on this node's code and configuration boots as the task does.
  test "boot_oban_inserts starts Oban on a node where only app.config has run" do
    {:ok, peer, _node} = :peer.start(%{connection: :standard_io})
    on_exit(fn -> if Process.alive?(peer), do: :peer.stop(peer) end)

    :ok = :peer.call(peer, :code, :add_pathsa, [:code.get_path()])

    env =
      for {app, _description, _vsn} <- Application.loaded_applications(),
          app not in [:kernel, :stdlib, :ex_unit, :mix, :iex, :elixir] do
        {app, Application.get_all_env(app)}
      end

    for {app, _config} <- env, do: :peer.call(peer, :application, :load, [app])
    :ok = :peer.call(peer, Application, :put_all_env, [env, [persistent: true]])
    :ok = :peer.call(peer, Logger, :configure, [[level: :error]])

    refute :peer.call(peer, Process, :whereis, [Oban.Registry])

    # One call, as the task is one process: what `start_link` starts is linked to the
    # caller, and each `:peer.call` runs in a process of its own that exits after it.
    {result, _binding} =
      :peer.call(
        peer,
        Code,
        :eval_string,
        [
          """
          :ok = AshEnterprise.Mix.Helpers.boot_repo()
          :ok = AshEnterprise.Mix.Helpers.boot_oban_inserts()
          # Idempotent: a task invoked by another task calls it again.
          :ok = AshEnterprise.Mix.Helpers.boot_oban_inserts()
          config = Oban.config()
          {config.queues, config.plugins}
          """
        ],
        :timer.minutes(1)
      )

    assert result == {[], []}
  end

  test "no configured level leaves the Logger alone" do
    Logger.configure(level: :notice)
    Application.delete_env(:logger, :level)

    assert :ok = Helpers.apply_logger_level()
    assert Logger.level() == :notice
  end
end
