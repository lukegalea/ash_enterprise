defmodule AshEnterprise.Test.Process.FlakyMailer do
  @moduledoc """
  A Swoosh adapter that fails the first `n` messages, or every message to some addresses,
  and hands the rest to `Swoosh.Adapters.Test`, so a test can prove that a failed message is
  retried and sent once, and that one address that always fails silences nobody else.
  Nothing leaves the test process either way.

      start_supervised!({AshEnterprise.Test.Process.FlakyMailer, failures: 1})
      start_supervised!({AshEnterprise.Test.Process.FlakyMailer, failing_addresses: [address]})
      AshEnterprise.Test.Process.FlakyMailer.install()
  """

  use Swoosh.Adapter
  use Agent

  @doc "Starts the counter of failures still to come."
  def start_link(opts) do
    state =
      case Keyword.fetch(opts, :failing_addresses) do
        {:ok, addresses} -> {:addresses, MapSet.new(addresses, &to_string/1)}
        :error -> Keyword.get(opts, :failures, 1)
      end

    Agent.start_link(fn -> state end, name: __MODULE__)
  end

  @doc """
  Makes `AshEnterprise.Mailer` send through this adapter until the test exits. Only for a
  test that is not async: the mailer's configuration is global.
  """
  def install do
    previous = Application.get_env(:ash_enterprise, AshEnterprise.Mailer)
    Application.put_env(:ash_enterprise, AshEnterprise.Mailer, adapter: __MODULE__)

    ExUnit.Callbacks.on_exit(fn ->
      Application.put_env(:ash_enterprise, AshEnterprise.Mailer, previous)
    end)
  end

  @impl true
  def deliver(email, config) do
    failing? =
      Agent.get_and_update(__MODULE__, fn
        {:addresses, addresses} = state ->
          {Enum.any?(email.to, fn {_name, address} -> address in addresses end), state}

        0 ->
          {false, 0}

        n ->
          {true, n - 1}
      end)

    if failing?,
      do: {:error, :mailer_unavailable},
      else: Swoosh.Adapters.Test.deliver(email, config)
  end
end
