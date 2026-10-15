defmodule Mix.Tasks.AshEnterprise.Erasure.Scopes do
  @shortdoc "Lists erasure scopes: what each one covers, and whether it is shredded"

  @moduledoc """
  Lists every erasure scope (ADR 0024) with its kind, ref, label and status, so
  an operator can find the one to shred.

      mix ash_enterprise.erasure.scopes

  Structural facts only: no key material and no content is read. See
  `docs/runbooks/crypto-shredding.md`.
  """

  use Mix.Task

  alias AshEnterprise.Erasure
  alias AshEnterprise.Mix.Helpers

  @requirements ["app.config"]

  @impl Mix.Task
  def run(_argv) do
    # Repo only: listing scopes must not start Oban, which would drain the very
    # ingestion queues an operator may be about to stop (iron law #23).
    Helpers.boot_repo()

    # Operator console: a person at a shell holding the database credentials
    # already sees these rows. The listing is structural; the shred is the
    # authorized step (see `ash_enterprise.erasure.shred`).
    scopes = Erasure.list_scopes!(authorize?: false, query: [sort: [kind: :asc, ref: :asc]])

    if scopes == [] do
      Mix.shell().info("No erasure scopes.")
    else
      Enum.each(scopes, fn scope ->
        Mix.shell().info(
          "#{scope.kind}:#{scope.ref}  #{status(scope)}  #{scope.label || ""}  (#{scope.id})"
        )
      end)
    end
  end

  defp status(%{status: :shredded, shredded_at: at}), do: "shredded #{DateTime.to_iso8601(at)}"
  defp status(%{status: :active}), do: "active"
end
