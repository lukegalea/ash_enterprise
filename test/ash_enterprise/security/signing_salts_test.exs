defmodule AshEnterprise.Security.SigningSaltsTest do
  @moduledoc """
  In production the session cookie salt and the LiveView salt come from the
  environment, and the release does not boot without them. A missing, blank or
  short value is a refusal to boot, never a fallback to a salt that sits in a
  public repository.
  """

  use ExUnit.Case, async: true

  alias AshEnterprise.Security.SigningSalts

  @good %{
    "SESSION_SIGNING_SALT" => String.duplicate("s", 32),
    "LIVE_VIEW_SIGNING_SALT" => String.duplicate("l", 32)
  }

  test "both salts present and long enough are returned" do
    assert %{session: session, live_view: live_view} = SigningSalts.fetch_from_env!(@good)
    assert session == @good["SESSION_SIGNING_SALT"]
    assert live_view == @good["LIVE_VIEW_SIGNING_SALT"]
  end

  for name <- ["SESSION_SIGNING_SALT", "LIVE_VIEW_SIGNING_SALT"] do
    test "boot fails when #{name} is unset" do
      assert_raise RuntimeError, ~r/#{unquote(name)}/, fn ->
        SigningSalts.fetch_from_env!(Map.delete(@good, unquote(name)))
      end
    end

    for {label, bad} <- [blank: "", spaces: String.duplicate(" ", 40), short: "abc"] do
      test "boot fails when #{name} is #{label}" do
        assert_raise RuntimeError, ~r/#{unquote(name)}/, fn ->
          SigningSalts.fetch_from_env!(Map.put(@good, unquote(name), unquote(bad)))
        end
      end
    end
  end

  test "the two salts must differ, so one leaked cookie salt does not sign LiveView" do
    same = %{@good | "LIVE_VIEW_SIGNING_SALT" => @good["SESSION_SIGNING_SALT"]}
    assert_raise RuntimeError, ~r/differ/, fn -> SigningSalts.fetch_from_env!(same) end
  end

  test "the endpoint takes its session salt from configuration at runtime" do
    salt = Application.fetch_env!(:ash_enterprise, :session_signing_salt)
    assert AshEnterpriseWeb.Endpoint.session_options()[:signing_salt] == salt
  end

  test "no salt is written into the endpoint or the shared config" do
    refute File.read!("lib/ash_enterprise_web/endpoint.ex") =~ ~r/signing_salt:\s*"/
    refute File.read!("config/config.exs") =~ ~r/signing_salt:\s*"/
  end

  test "the production config reads both salts through the checked path" do
    runtime = File.read!("config/runtime.exs")
    assert runtime =~ "SigningSalts.fetch_from_env!"
  end

  test "the dev and test built-in salts are the ones the boot check refuses" do
    for file <- ["config/dev.exs", "config/test.exs"],
        [_, value] <- Regex.scan(~r/(?:session_signing_salt:|signing_salt:)\s*"([^"]+)"/, File.read!(file)) do
      assert value in SigningSalts.built_in(), "#{file} salt #{inspect(value)} is not registered"
    end
  end

  for name <- ["SESSION_SIGNING_SALT", "LIVE_VIEW_SIGNING_SALT"],
      salt <- SigningSalts.built_in() do
    test "boot fails when #{name} is the built-in salt #{salt}" do
      assert_raise RuntimeError, ~r/built-in/, fn ->
        SigningSalts.fetch_from_env!(Map.put(@good, unquote(name), unquote(salt)))
      end
    end
  end
end
