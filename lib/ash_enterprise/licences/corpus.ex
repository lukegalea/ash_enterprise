defmodule AshEnterprise.Licences.Corpus do
  @moduledoc """
  Loads the hex.pm licence corpus (S1-63's research input, public package
  metadata) as licence subjects.

  Three files, in the programme repo's formats:

    * the corpus: `package, latest_stable_version, downloads,
      declared_licenses_raw, ...`, one row per release, with the hex
      `licenses` declaration verbatim and `|`-joined;
    * the triaged anomalies: `package, declared_licenses_raw,
      anomaly_kinds, reason, ...`. These releases stay out of the subject
      set, each with its recorded reason (a declaration the crawl had to
      normalise, a list with no OR/AND, no SPDX id at all). A corpus row with
      no stable release version is excluded too: the subject is a release.
    * optionally, the package contents read from each release tarball
      (JSON lines: `package, version, licence_text, files,
      notice_file_present`).

  Parsing only: `subjects/3` returns the attribute maps for
  `AshEnterprise.Licences.register_dependency/2` and the exclusions.
  """

  alias NimbleCSV.RFC4180, as: CSV

  # Sobelow reads `@sobelow_skip` from the source AST; persisting it keeps
  # `--warnings-as-errors` from calling it unused (see Audit.Export).
  Module.register_attribute(__MODULE__, :sobelow_skip, persist: true)

  @type exclusion :: %{
          package: String.t(),
          declared: String.t(),
          kinds: String.t(),
          reason: String.t()
        }

  @doc """
  The corpus as subject attribute maps, minus the triaged anomalies.
  Returns `%{subjects: [map()], excluded: [exclusion()]}`.
  """
  @spec subjects(Path.t(), Path.t(), Path.t() | nil) :: %{
          subjects: [map()],
          excluded: [exclusion()]
        }
  def subjects(corpus_path, anomalies_path, contents_path \\ nil) do
    excluded =
      anomalies_path
      |> rows()
      |> Enum.map(fn row ->
        %{
          package: row["package"],
          declared: row["declared_licenses_raw"],
          kinds: row["anomaly_kinds"],
          reason: row["reason"]
        }
      end)

    excluded_names = MapSet.new(excluded, & &1.package)
    contents = contents(contents_path)

    {versioned, unversioned} =
      corpus_path
      |> rows()
      |> Enum.reject(&MapSet.member?(excluded_names, &1["package"]))
      |> Enum.split_with(&(&1["latest_stable_version"] != ""))

    excluded =
      excluded ++
        Enum.map(unversioned, fn row ->
          %{
            package: row["package"],
            declared: row["declared_licenses_raw"],
            kinds: "no_version",
            reason:
              "the corpus records no stable release (pre-release only), so there is no release to be the subject"
          }
        end)

    subjects =
      versioned
      |> Enum.map(fn row ->
        package = row["package"]
        version = row["latest_stable_version"]

        %{
          package: package,
          version: version,
          repository: "hexpm",
          declared_licences: declared(row["declared_licenses_raw"])
        }
        |> Map.merge(Map.get(contents, {package, version}, %{}))
      end)

    %{subjects: subjects, excluded: excluded}
  end

  defp declared(""), do: []
  defp declared(raw), do: String.split(raw, "|")

  defp contents(nil), do: %{}

  # The corpus paths are the caller's research files (a test fixture, a
  # programme-repo script argument), never request input. Skipped by name and
  # locally: if request input ever reaches these functions, that is a real
  # finding.
  @sobelow_skip ["Traversal.FileModule"]
  defp contents(path) do
    path
    |> File.stream!()
    |> Stream.map(&Jason.decode!/1)
    |> Stream.reject(&Map.has_key?(&1, "error"))
    |> Map.new(fn row ->
      {{row["package"], row["version"]},
       %{
         licence_text: row["licence_text"],
         package_files: row["files"],
         notice_file_present: row["notice_file_present"]
       }}
    end)
  end

  @sobelow_skip ["Traversal.FileModule"]
  defp rows(path) do
    [header | rows] = path |> File.read!() |> CSV.parse_string(skip_headers: false)
    Enum.map(rows, fn row -> header |> Enum.zip(row) |> Map.new() end)
  end
end
