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

  test "no configured level leaves the Logger alone" do
    Logger.configure(level: :notice)
    Application.delete_env(:logger, :level)

    assert :ok = Helpers.apply_logger_level()
    assert Logger.level() == :notice
  end
end
