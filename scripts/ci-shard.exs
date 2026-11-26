# Time-balanced test sharding for CI.
#
#   elixir scripts/ci-shard.exs files  SHARD TOTAL   # print this shard's files, one per line
#   elixir scripts/ci-shard.exs check  TOTAL         # assert every file is in exactly one shard
#   elixir scripts/ci-shard.exs plan   TOTAL         # print each shard's predicted seconds
#   elixir scripts/ci-shard.exs timings [--blend] LOG...
#                                                    # rewrite test/support/ci_timings.json
#                                                    # from CI shard logs (see below)
#
# Files are assigned longest-first to the currently lightest shard, using the
# seconds recorded in test/support/ci_timings.json. A file missing from that
# file (a new test) gets the median recorded weight, so it still lands
# somewhere sensible. battery/ is its own mix project and is not under test/.
#
# Refreshing the timings: the shard jobs run `mix test --slowest-modules`,
# which implies --trace, so each module prints a `Module [test/x_test.exs]`
# header with a timestamp. The suite is synchronous, so a module's duration is
# the gap to the next header (the last one runs to "Finished in"). Only files
# that exist in this checkout are written, so a renamed or deleted test drops
# out.
#
# Every green CI run does this already: the `Test suite (all shards)` job
# blends its shards' logs into the committed file (--blend), uploads it as the `ci-timings`
# artifact and says in its summary how many files the committed one is
# missing. Commit it when that number grows, or when the plan's shards drift
# apart (2026-11-26: 207 of 420 files unrecorded, shards from 17 to 55 min):
#
#   gh run download RUN -n ci-timings -D test/support
#
# By hand, from the logs of green runs, one file per shard job:
#
#   gh api repos/OWNER/REPO/actions/jobs/JOB/logs > /tmp/shard-N.log   # per shard job
#   elixir scripts/ci-shard.exs timings /tmp/shard-*.log
#
# Logs from several runs are averaged per file, and --blend averages the result
# with the committed timings. Use more than one run when you can: runner speed
# differs between jobs, so a single run's timings carry the speed of the
# runners it drew.
defmodule CiShard do
  @timings "test/support/ci_timings.json"

  def main(["files", shard, total]) do
    {shard, total} = {String.to_integer(shard), String.to_integer(total)}

    shards(total)
    |> Enum.at(shard - 1)
    |> Enum.map(&elem(&1, 0))
    |> Enum.sort()
    |> Enum.each(&IO.puts/1)
  end

  def main(["check", total]) do
    total = String.to_integer(total)
    all = test_files()
    assigned = shards(total) |> List.flatten() |> Enum.map(&elem(&1, 0))

    dupes = assigned -- Enum.uniq(assigned)
    missing = all -- assigned
    extra = assigned -- all

    if dupes == [] and missing == [] and extra == [] and length(assigned) == length(all) do
      IO.puts("ok: #{length(all)} test files, each in exactly one of #{total} shards")

      case unrecorded() do
        [] ->
          :ok

        files ->
          IO.puts(
            "#{length(files)} of #{length(all)} files have no recorded timing and weigh the median " <>
              "(#{round(median())}s); refresh #{@timings} (see the header of this script)"
          )
      end
    else
      IO.puts(
        :stderr,
        "shard assignment is wrong: dupes=#{inspect(dupes)} missing=#{inspect(missing)} extra=#{inspect(extra)}"
      )

      System.halt(1)
    end
  end

  def main(["plan", total]) do
    shards(String.to_integer(total))
    |> Enum.with_index(1)
    |> Enum.each(fn {fs, i} ->
      IO.puts(
        "shard #{i}: #{length(fs)} files, #{Enum.sum(Enum.map(fs, &elem(&1, 1))) |> round()}s"
      )
    end)
  end

  def main(["timings", "--blend" | logs]) when logs != [], do: write_timings(logs, true)
  def main(["timings" | logs]) when logs != [], do: write_timings(logs, false)

  def main(_),
    do:
      (
        IO.puts(:stderr, "usage: see the header of scripts/ci-shard.exs")
        System.halt(2)
      )

  # Each log is one shard job. A file's seconds within a log are summed (a file
  # can hold several modules); across logs they are averaged, so the logs of
  # several runs give each file its mean. GitHub's runners differ in speed by up
  # to half between jobs of one run, and every file in a shard carries its
  # runner's speed, so one run's timings are biased by the runners it drew.
  # --blend also averages with the committed timings, which is how CI refreshes
  # them: each refresh moves halfway towards the latest run.
  defp write_timings(logs, blend?) do
    samples =
      Enum.reduce(logs, %{}, fn log, acc ->
        log
        |> File.read!()
        |> parse_log()
        |> Enum.reduce(%{}, fn {f, s}, a -> Map.update(a, f, s, &(&1 + s)) end)
        |> Enum.reduce(acc, fn {f, s}, a -> Map.update(a, f, [s], &[s | &1]) end)
      end)

    measured = Map.new(samples, fn {f, ss} -> {f, Enum.sum(ss) / length(ss)} end)

    timings =
      if blend?,
        do: Map.merge(recorded(), measured, fn _f, old, new -> (old + new) / 2 end),
        else: measured

    present = MapSet.new(test_files())

    ordered =
      timings
      |> Enum.filter(fn {f, _} -> MapSet.member?(present, f) end)
      |> Enum.sort_by(fn {f, s} -> {-s, f} end)
      |> Enum.map(fn {f, s} -> {f, Float.round(s * 1.0, 1)} end)

    body = Enum.map_join(ordered, ",\n", fn {f, s} -> ~s(  #{JSON.encode!(f)}: #{s}) end)
    File.write!(@timings, "{\n" <> body <> "\n}\n")
    IO.puts("wrote #{length(ordered)} timings to #{@timings}")
  end

  # test/playwright is the Playwright tier's, which runs in dev against the dev server
  # (`mix test.playwright`, the e2e job), never in a shard.
  defp test_files,
    do:
      Path.wildcard("test/**/*_test.exs")
      |> Enum.reject(&String.starts_with?(&1, "test/playwright/"))
      |> Enum.sort()

  defp recorded do
    if File.exists?(@timings), do: @timings |> File.read!() |> JSON.decode!(), else: %{}
  end

  defp median do
    sorted = recorded() |> Map.values() |> Enum.sort()
    if sorted == [], do: 1.0, else: Enum.at(sorted, div(length(sorted), 2)) * 1.0
  end

  defp unrecorded do
    recorded = recorded()
    Enum.reject(test_files(), &Map.has_key?(recorded, &1))
  end

  defp weights do
    {recorded, default} = {recorded(), median()}
    for f <- test_files(), do: {f, Map.get(recorded, f, default) * 1.0}
  end

  defp shards(total) do
    empty = for _ <- 1..total, do: {0.0, []}

    weights()
    |> Enum.sort_by(fn {f, w} -> {-w, f} end)
    |> Enum.reduce(empty, fn {f, w} = item, bins ->
      _ = f

      {{load, files}, idx} =
        bins |> Enum.with_index() |> Enum.min_by(fn {{l, _}, i} -> {l, i} end)

      List.replace_at(bins, idx, {load + w, [item | files]})
    end)
    |> Enum.map(fn {_, files} -> files end)
  end

  # `gh run view --log` lines look like
  #   "Test shard 1 of 6\tTest\t2026-11-01T07:19:05.1509343Z Mod [test/x_test.exs]"
  defp parse_log(text) do
    {events, finish} =
      text
      |> String.split("\n")
      |> Enum.reduce({[], nil}, fn line, {ev, fin} ->
        line = String.replace(line, "﻿", "")

        cond do
          m = Regex.run(~r/(\d{4}-\d\d-\d\dT[\d:.]+)Z \S+ \[(test\/[^\]]+_test\.exs)\]\s*$/, line) ->
            [_, t, f] = m
            {[{ts(t), f} | ev], fin}

          m = Regex.run(~r/(\d{4}-\d\d-\d\dT[\d:.]+)Z Finished in /, line) ->
            {ev, ts(Enum.at(m, 1))}

          true ->
            {ev, fin}
        end
      end)

    events = Enum.reverse(events)
    ends = Enum.map(Enum.drop(events, 1), &elem(&1, 0)) ++ [finish]

    events
    |> Enum.zip(ends)
    |> Enum.flat_map(fn
      {{_t, _f}, nil} -> []
      {{t, f}, e} -> [{f, max(DateTime.diff(e, t, :millisecond) / 1000, 0.0)}]
    end)
  end

  defp ts(s) do
    {:ok, dt, _} = DateTime.from_iso8601(String.slice(s, 0, 26) <> "Z")
    dt
  end
end

CiShard.main(System.argv())
