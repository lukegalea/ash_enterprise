# Fail when battery/mix.lock resolves a shared package differently from mix.lock.
#
# The battery (battery/README.md, "Pins") proves the seams between the
# substrates the platform ships, so it has to resolve the same code the
# platform resolves. Its lock is a separate file that nothing kept in step:
# by 2026-10-29 sixteen of its seventy-five shared entries had drifted, three
# of them substrates, and the battery was quietly proving seams between
# versions the platform no longer ran.
#
# Every package present in both locks must have an identical entry: the same
# hex version (and so the same checksum), or the same git url, ref and
# options. Packages only one side locks are not compared -- the host locks far
# more than the battery needs, and a dependency only the battery has is its
# own business.
#
# Usage, from the repository root:
#
#     elixir scripts/battery-pins-check.exs           # check; non-zero on drift
#     elixir scripts/battery-pins-check.exs --sync    # copy the host's entries
#
# --sync rewrites the drifted lines of battery/mix.lock from mix.lock, line for
# line, and touches nothing else. Follow it with `mix deps.get` in battery/
# (which picks up any new transitive dependency), then run the check again:
# a substrate bump can pull in a package whose entry needs the same treatment.
# A git entry whose options differ (a `branch:` one side declares and the
# other does not) also needs the declaration in battery/mix.exs changed to
# match the host's mix.exs, or `mix deps.get` will relock it.

defmodule BatteryPins do
  # A package that genuinely cannot resolve the same way in the battery goes
  # here, with the reason. The check skips it by name and says so. Keep this
  # empty unless there is a reason that would survive review: the point of the
  # battery is that it runs what the platform runs.
  @exceptions %{}

  @host "mix.lock"
  @battery "battery/mix.lock"

  def main(args) do
    root = repo_root()
    host = read_lock!(Path.join(root, @host))
    battery = read_lock!(Path.join(root, @battery))

    for {name, reason} <- @exceptions do
      IO.puts("battery-pins: #{name} is exempt -- #{reason}")
    end

    drift =
      host
      |> Map.keys()
      |> Enum.filter(&Map.has_key?(battery, &1))
      |> Enum.reject(&Map.has_key?(@exceptions, &1))
      |> Enum.sort()
      |> Enum.reject(&(host[&1] == battery[&1]))

    case {args, drift} do
      {[], []} ->
        IO.puts("battery-pins: battery/mix.lock matches mix.lock on every shared package")

      {[], drift} ->
        report(drift, host, battery)
        System.halt(1)

      {["--sync"], []} ->
        IO.puts("battery-pins: nothing to sync")

      {["--sync"], drift} ->
        sync!(Path.join(root, @host), Path.join(root, @battery), drift)

      _ ->
        IO.puts(:stderr, "usage: elixir scripts/battery-pins-check.exs [--sync]")
        System.halt(2)
    end
  end

  defp report(drift, host, battery) do
    IO.puts(:stderr, "battery-pins: #{length(drift)} shared package(s) resolve differently:\n")

    for name <- drift do
      IO.puts(
        :stderr,
        "  #{name}: host #{describe(host[name])}, battery #{describe(battery[name])}"
      )
    end

    IO.puts(:stderr, """

    The battery must resolve what the platform resolves (battery/README.md, "Pins").
    Align it and commit battery/mix.lock:

        elixir scripts/battery-pins-check.exs --sync
        (cd battery && devenv shell -- mix deps.get)
        elixir scripts/battery-pins-check.exs
    """)

    for name <- drift, options_differ?(host[name], battery[name]) do
      IO.puts(
        :stderr,
        "  #{name}: the git options differ too -- declare it in battery/mix.exs as mix.exs does."
      )
    end
  end

  defp options_differ?({:git, _, _, host_opts}, {:git, _, _, battery_opts}),
    do: host_opts != battery_opts

  defp options_differ?(_host, _battery), do: false

  defp describe({:hex, _name, version, _hash, _managers, _deps, _repo, _outer}), do: version
  defp describe({:hex, _name, version, _hash, _managers, _deps, _repo}), do: version

  defp describe({:git, url, ref, opts}) do
    short = String.slice(ref, 0, 7)
    base = "#{Path.basename(url, ".git")}@#{short}"
    if opts == [], do: base, else: "#{base} #{inspect(opts)}"
  end

  defp describe(other), do: inspect(other, limit: 4)

  # Line-level so the lock keeps the exact layout mix writes (one entry per
  # line) and the diff shows only the entries that moved.
  defp sync!(host_path, battery_path, drift) do
    host_lines = lines_by_name(host_path)
    wanted = MapSet.new(drift)

    synced =
      battery_path
      |> File.read!()
      |> String.split("\n")
      |> Enum.map(fn line ->
        case entry_name(line) do
          {:ok, name} ->
            if MapSet.member?(wanted, name), do: Map.fetch!(host_lines, name), else: line

          :error ->
            line
        end
      end)
      |> Enum.join("\n")

    File.write!(battery_path, synced)

    for name <- drift, do: IO.puts("battery-pins: synced #{name}")
    IO.puts("battery-pins: now run `mix deps.get` in battery/ and check again")
  end

  defp lines_by_name(path) do
    for line <- path |> File.read!() |> String.split("\n"),
        {:ok, name} <- [entry_name(line)],
        into: %{},
        do: {name, line}
  end

  defp entry_name(line) do
    case Regex.run(~r/^\s+"([^"]+)": \{/, line) do
      [_, name] -> {:ok, name}
      _ -> :error
    end
  end

  # Read the way mix reads a lock: parse without the quoted-key warnings, then
  # evaluate the literal.
  defp read_lock!(path) do
    with {:ok, contents} <- File.read(path),
         {:ok, quoted} <- Code.string_to_quoted(contents, emit_warnings: false),
         {%{} = lock, _binding} <- Code.eval_quoted(quoted) do
      Map.new(lock, fn {name, entry} -> {to_string(name), entry} end)
    else
      error ->
        IO.puts(:stderr, "battery-pins: could not read #{path}: #{inspect(error)}")
        System.halt(2)
    end
  end

  defp repo_root do
    case System.cmd("git", ["rev-parse", "--show-toplevel"], stderr_to_stdout: true) do
      {root, 0} -> String.trim(root)
      _ -> File.cwd!()
    end
  end
end

BatteryPins.main(System.argv())
