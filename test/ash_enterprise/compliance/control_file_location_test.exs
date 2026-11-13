defmodule AshEnterprise.Compliance.ControlFileLocationTest do
  @moduledoc """
  Where the freshness sweep and the audit package find the control file
  (`AshEnterprise.Compliance.FreshnessSweepWorker.controls_file/0`).

  A release runs from its own root, which has no `docs/` directory, so the configured
  relative path is not there and every criterion would sweep as `unknown` with
  `control_file_missing`. The release carries a copy in its priv (`copy_control_file/1` in
  `mix.exs`), and the worker falls back to it. The missing cases come first.
  """

  use ExUnit.Case, async: true

  alias AshEnterprise.Compliance.FreshnessSweepWorker

  setup do
    dir = Path.join(System.tmp_dir!(), "control-file-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  describe "resolve/2" do
    test "with neither file there, answers the configured path, so the sweep names it missing",
         %{dir: dir} do
      configured = Path.join(dir, "docs/controls.json")
      copy = Path.join(dir, "priv/compliance/controls.json")

      assert FreshnessSweepWorker.resolve(configured, copy) == configured
    end

    test "a directory where the file should be is not the file", %{dir: dir} do
      configured = Path.join(dir, "docs/controls.json")
      File.mkdir_p!(configured)
      copy = write!(Path.join(dir, "priv/compliance/controls.json"))

      assert FreshnessSweepWorker.resolve(configured, copy) == copy
    end

    test "in a release, where the configured path is absent, answers the release's copy",
         %{dir: dir} do
      copy = write!(Path.join(dir, "priv/compliance/controls.json"))

      assert FreshnessSweepWorker.resolve("docs/no-such-controls.json", copy) == copy
    end

    test "in a source checkout, the configured path wins", %{dir: dir} do
      configured = write!(Path.join(dir, "docs/controls.json"))
      copy = write!(Path.join(dir, "priv/compliance/controls.json"))

      assert FreshnessSweepWorker.resolve(configured, copy) == configured
    end
  end

  test "here, in a source checkout, the sweep reads the control file that exists" do
    assert File.regular?(FreshnessSweepWorker.controls_file())
  end

  test "the release step copies the control file into the release's priv, unchanged", %{
    dir: dir
  } do
    release = %Mix.Release{
      name: :ash_enterprise,
      path: dir,
      applications: %{ash_enterprise: [vsn: ~c"9.9.9"]}
    }

    assert %Mix.Release{} = AshEnterprise.MixProject.copy_control_file(release)

    copied =
      Path.join([dir, "lib", "ash_enterprise-9.9.9", "priv", "compliance", "controls.json"])

    assert File.read!(copied) == File.read!("docs/controls.json")

    # And it is where the worker looks, relative to the application's own directory.
    assert FreshnessSweepWorker.resolve("docs/absent.json", copied) == copied
  end

  defp write!(path) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "{}")
    path
  end
end
