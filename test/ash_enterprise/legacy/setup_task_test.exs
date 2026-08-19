defmodule AshEnterprise.Legacy.SetupTaskTest do
  @moduledoc """
  How `mix ash_enterprise.legacy.setup` invokes `psql`.

  Narrow tests for one specific failure, recorded because it was expensive and
  because nothing about it was visible. The task shells out to psql, and psql
  asks the *terminal* for a password whenever the server wants one — which every
  CI postgres service does, since they are started with `POSTGRES_PASSWORD`.
  `System.cmd/3` hands it a terminal that will never answer, so the task hung
  until the job timed out: 37 minutes of a run that reported nothing but "in
  progress", with no output to read and no error to search for.

  A hang is the worst possible failure mode for a setup step, so the two
  properties that prevent it are asserted rather than assumed.
  """

  use ExUnit.Case, async: true

  alias Mix.Tasks.AshEnterprise.Legacy.Setup

  test "psql can never prompt for a password" do
    # Without `--no-password`, psql blocks on stdin. With it, a server that wants
    # a password produces an immediate authentication error instead — a failure
    # someone can read.
    assert "--no-password" in Setup.psql_args()
  end

  test "it fails on the first error rather than reporting a partial apply" do
    args = Setup.psql_args()

    assert "ON_ERROR_STOP=1" in args
    assert "--set" in args
  end

  test "nothing tries to hand psql a password as an argument" do
    # psql has no option that takes one, by design -- arguments are visible in
    # `ps` to every user on the machine -- so an attempt to pass one would be a
    # misunderstanding of the tool rather than a leak. `-W` is the opposite of
    # what this needs: it forces a prompt.
    args = Setup.psql_args()

    refute "-W" in args
    refute "--password" in args
    refute Enum.any?(args, &String.contains?(&1, "password="))
  end

  test "the credentials come from the repo's own config, so they cannot drift" do
    args = Setup.psql_args()
    config = AshEnterprise.Repo.config()

    assert to_string(config[:database]) in args
    assert to_string(config[:username]) in args
    assert to_string(config[:port]) in args
  end

  test "a configured password is exported as PGPASSWORD" do
    case AshEnterprise.Repo.config()[:password] do
      blank when blank in [nil, ""] ->
        # The local devenv cluster trusts local connections. Exporting an empty
        # PGPASSWORD there would be a password *attempt* rather than the absence
        # of one, so nothing is exported.
        assert Setup.psql_env() == []

      password ->
        assert {"PGPASSWORD", to_string(password)} in Setup.psql_env()
    end
  end
end
