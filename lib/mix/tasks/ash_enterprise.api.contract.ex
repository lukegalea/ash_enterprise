defmodule Mix.Tasks.AshEnterprise.Api.Contract do
  @shortdoc "Pin the public API contract, or check that it has not drifted"

  @moduledoc """
  The OpenAPI document and the GraphQL schema are committed under `priv/api/`.

      mix ash_enterprise.api.contract --check   # fail on any drift from the pin
      mix ash_enterprise.api.contract --check --base origin/main
                                                # and on an unannounced breaking change
      mix ash_enterprise.api.contract --write   # re-pin the contract

  `--check` fails when the API generated from the resources differs from the pin, when
  a pinned file was edited by hand (`contract.lock.json`), and when
  `priv/api/deprecations.json` names something the contract does not hold.

  `--write` refuses a breaking change (a removed route, property, GraphQL field or
  argument, a changed type, something newly required of a caller) unless
  `deprecations.json` announced it and its sunset has passed. An additive change
  re-pins freely. See `docs/runbooks/changing-the-api.md`.

  `--base REF` is the gate CI runs, because `--write` runs on the author's machine and the
  files it writes can be written by hand. It compares the committed pin with the pin at the
  merge base of `REF` and `HEAD`, and fails on a breaking change that the merge base's own
  `deprecations.json` did not announce with the minimum notice and a sunset that has passed
  (`AshEnterpriseWeb.ApiContract.check_against/3`). A `REF` that is not a commit here (a
  push that created its branch reports all zeros) falls back to `origin/main`.
  """

  use Mix.Task

  alias AshEnterpriseWeb.ApiContract

  @requirements ["app.config"]

  @impl Mix.Task
  def run(argv) do
    {opts, _rest} =
      OptionParser.parse!(argv, strict: [check: :boolean, write: :boolean, base: :string])

    Mix.Task.run("compile")

    cond do
      opts[:check] ->
        check()
        if base = opts[:base], do: check_against(base)

      opts[:write] ->
        write()

      true ->
        Mix.raise("pass --check or --write")
    end
  end

  defp check_against(ref) do
    case merge_base(ref) do
      nil -> Mix.shell().info("No base to compare the API contract with (#{ref}, origin/main).")
      base -> base |> ApiContract.check_against() |> report_against()
    end
  end

  defp report_against({:ok, notes}), do: Enum.each(notes, fn note -> Mix.shell().info(note) end)

  defp report_against({:error, problems}) do
    Mix.shell().error(
      "\nThe API contract changed in a way callers were not told about:\n\n" <>
        Enum.map_join(problems, "\n", &"  #{&1}") <>
        "\n\nSee docs/runbooks/changing-the-api.md.\n"
    )

    exit({:shutdown, 1})
  end

  # The merge base of `ref` (or of origin/main when `ref` is not a commit here) with HEAD.
  defp merge_base(ref) do
    Enum.find_value([ref, "origin/main"], fn candidate ->
      with {_, 0} <-
             System.cmd("git", ["rev-parse", "--verify", "--quiet", candidate <> "^{commit}"],
               stderr_to_stdout: true
             ),
           {base, 0} <- System.cmd("git", ["merge-base", candidate, "HEAD"]) do
        String.trim(base)
      else
        _ -> nil
      end
    end)
  end

  defp check do
    case ApiContract.check() do
      {:ok, _} ->
        Mix.shell().info("The API matches the pinned contract in priv/api/.")

      {:error, problems} ->
        Mix.shell().error(
          "\nThe API contract check failed:\n\n" <>
            Enum.map_join(problems, "\n", &"  #{&1}") <> "\n"
        )

        exit({:shutdown, 1})
    end
  end

  defp write do
    case ApiContract.write() do
      {:ok, paths} ->
        Mix.shell().info("Pinned " <> Enum.join(Enum.sort(paths), ", ") <> ".")

      {:error, refused} ->
        lines = Enum.map_join(refused, "\n", &"  #{&1.element}: #{&1.reason}")

        Mix.shell().error("""

        Not pinned: these changes break callers and no announcement permits them.

        #{lines}

        Announce each in priv/api/deprecations.json (at least #{ApiContract.Deprecations.minimum_notice_days()} days before its sunset),
        keep it until the sunset has passed, then remove it. See docs/runbooks/changing-the-api.md.
        """)

        exit({:shutdown, 1})
    end
  end
end
