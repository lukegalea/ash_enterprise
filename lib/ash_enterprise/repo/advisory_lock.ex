defmodule AshEnterprise.Repo.AdvisoryLock do
  @moduledoc """
  A Postgres session advisory lock around work that must not run twice at
  once but is too long to hold one transaction for — the MDM people sweep,
  which a mix task and the cron's job can both start for one tenant.

  The lock is database-wide, so it holds across nodes: the dogfood
  application's Oban job and a `mix` VM on the same database exclude each
  other. It lives on one connection, so `with_try_lock/3` checks a
  connection out for the whole of `fun` (every Repo call `fun` makes from
  this process runs on it) and unlocks before giving it back. A crashed or
  killed holder loses its session, and Postgres releases the lock with it.

  Raw SQL by design: an advisory lock is a SQL-only feature on no Ash table
  (ash-discipline, exception 3). The key is two strings hashed by Postgres
  (`hashtext/1`), so a caller names a namespace and a key, never a number.
  """

  alias AshEnterprise.Repo

  @doc """
  Runs `fun` while holding the `{namespace, key}` lock: `{:ok, fun_result}`,
  or `:busy` without running it when another session holds the lock.
  """
  @spec with_try_lock(String.t(), String.t(), (-> result)) :: {:ok, result} | :busy
        when result: term()
  def with_try_lock(namespace, key, fun)
      when is_binary(namespace) and is_binary(key) and is_function(fun, 0) do
    Repo.checkout(fn ->
      %{rows: [[locked?]]} =
        Repo.query!("SELECT pg_try_advisory_lock(hashtext($1), hashtext($2))", [namespace, key])

      if locked? do
        try do
          {:ok, fun.()}
        after
          # Not the bang form: a connection that died under `fun` took the
          # lock with it, and its error is the one worth raising.
          _ =
            Repo.query("SELECT pg_advisory_unlock(hashtext($1), hashtext($2))", [namespace, key])
        end
      else
        :busy
      end
    end)
  end
end
