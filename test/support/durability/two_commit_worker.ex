defmodule AshEnterprise.Durability.TwoCommitWorker do
  @moduledoc """
  The durability harness's probe: a job that makes two commits with a fault point between them.

  The first commit opens a currency at a provisional rate; the second settles it. Between them
  sits `AshEnterprise.Faults.point(:two_commit_worker_between_commits)`, so a test can stop the
  job exactly where a crash leaves half the work committed.

  Written the way a durable job has to be: every attempt starts by finding what an earlier
  attempt committed, so a retry after the fault resumes rather than repeating the first commit.
  """

  use Oban.Worker,
    queue: :durability,
    max_attempts: 3,
    unique: [period: :infinity, keys: [:tenant, :code]]

  alias AshEnterprise.Faults
  alias AshEnterprise.Platform.SystemActor
  alias AshEnterprise.Reference.Currency

  @fault_point :two_commit_worker_between_commits
  @provisional_rate Decimal.new("1")
  @settled_rate Decimal.new("2")

  @doc "The fault point between the two commits."
  def fault_point, do: @fault_point

  @doc "The rate the first commit writes."
  def provisional_rate, do: @provisional_rate

  @doc "The rate the second commit writes."
  def settled_rate, do: @settled_rate

  # Seconds, not Oban's default minutes: the harness waits for the retry. A test that wants to
  # look at the failed attempt before it is retried asks for longer with `"retry_in"`.
  @impl Oban.Worker
  def backoff(%Oban.Job{args: args}), do: Map.get(args, "retry_in", 1)

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"tenant" => tenant, "code" => code}}) do
    currency = find(tenant, code) || open!(tenant, code)

    Faults.point(@fault_point)

    Currency.update!(currency, %{exchange_rate: @settled_rate}, opts(tenant))
    :ok
  end

  @doc "The currency `code` in `tenant`, as committed now, or nil."
  def find(tenant, code) do
    Currency.read!(Keyword.put(opts(tenant), :query, filter: [iso_currency_code: code]))
    |> List.first()
  end

  defp open!(tenant, code) do
    Currency.create!(
      %{
        iso_currency_code: code,
        currency_name: "Probe #{code}",
        currency_symbol: code,
        currency_precision: 2,
        exchange_rate: @provisional_rate
      },
      opts(tenant)
    )
  end

  # Authorization is not what this probe is about; the actor is named so the audit trail says
  # who wrote the rows.
  defp opts(tenant),
    do: [actor: SystemActor.process(), tenant: tenant, authorize?: false]
end
