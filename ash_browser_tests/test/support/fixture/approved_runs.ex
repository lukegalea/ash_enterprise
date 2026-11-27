defmodule AshBrowserTests.Fixture.ApprovedRuns do
  @moduledoc false
  # Approved runs of the fixture's journeys under a fresh project root, written
  # the way the runner writes a passing run and published by
  # `AshJourneys.Approval.approve/4`, the function `mix ash_journeys.approve`
  # calls. The documentation ledger is then tested against a real lock, with no
  # browser.

  alias AshJourneys.{Approval, Json, L10n, Lock, Manifest, Raster, Run}
  alias AshJourneys.Manifest.{Figure, Step}

  @browser %{name: "chromium", version: "158.0.8127.18", executable: "/opt/chromium/chrome"}
  @manifest_opts [catalog: :admin_v1, locale: "en"]

  @doc "The `AshA2ui.Manifest` options the runs' labels resolve with."
  def manifest_opts, do: @manifest_opts

  @doc "A fresh project root, removed when the test exits."
  def root do
    root =
      Path.join(System.tmp_dir!(), "ash_browser_tests_lock_#{System.unique_integer([:positive])}")

    File.rm_rf!(root)
    File.mkdir_p!(root)
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf!(root) end)
    root
  end

  @doc "Writes a passing run of each `journey` of `modules` in `locale` as run `run_id`, and approves it."
  def approve!(root, modules, run_id, journeys, locale \\ "en") do
    {:ok, declared} = Lock.declared(modules)

    for journey <- journeys do
      manifest = manifest(declared, run_id, journey, locale)
      dir = Run.candidate_dir(root, run_id, journey, locale)
      Manifest.write!(manifest, dir)

      for %Step{figures: figures} <- manifest.steps,
          figure <- figures,
          do: File.write!(Path.join(dir, figure.file), Raster.encode(raster()))
    end

    {:ok, _} = Approval.approve(root, run_id, declared, manifest_opts: @manifest_opts)
    :ok
  end

  defp raster do
    %Raster{width: 4, height: 3, rgba: :binary.copy(<<20, 40, 60, 255>>, 12)}
  end

  defp manifest(declared, run_id, journey, locale) do
    %{ir: ir, hash: hash} = declared[journey]
    {:ok, texts} = L10n.texts(declared[journey], locale, @manifest_opts)
    raster = raster()

    steps =
      ir["steps"]
      |> Enum.with_index()
      |> Enum.map(fn {step, index} ->
        traced? = Enum.any?(step["body"], &(&1["type"] == "expect" and &1["trace"] != []))

        figures =
          for %{"type" => "figure"} = figure <- step["body"] do
            %Figure{
              name: figure["name"],
              file: Manifest.figure_key(step["name"], figure["name"]) <> ".png",
              file_sha256: Json.sha256(Raster.encode(raster)),
              raster_sha256: Raster.hash(raster),
              width: raster.width,
              height: raster.height,
              settled: true,
              highlight: if(figure["highlight"], do: %{x: 0, y: 0, width: 4, height: 1})
            }
          end

        %Step{
          name: step["name"],
          actor: step["as"],
          label: "#{index + 1}. #{step["name"]}",
          status: :passed,
          attempts: 1,
          cursor: %{from: index * 3, to: index * 3 + 3},
          correlation_id: if(traced?, do: "corr-#{index}"),
          span_ids: if(traced?, do: ["span-#{index}"], else: []),
          figures: figures
        }
      end)

    %Manifest{
      run_id: run_id,
      commit: String.duplicate("0", 40),
      journey: journey,
      version: ir["version"],
      declaration_hash: hash,
      locale: locale,
      environment: :test,
      browser: @browser,
      framing: %{
        "viewport" => %{"width" => 1280, "height" => 800},
        "device_scale_factor" => 1,
        "reduced_motion" => "reduce"
      },
      retries: 0,
      texts: texts,
      status: :passed,
      steps: steps
    }
  end
end
