defmodule AshEnterprise.GuidesTest do
  @moduledoc """
  The in-app guides (`AshEnterprise.Guides`): one registry entry per approved
  journey, whose label and blurb are the journey's title and goal in every locale it
  declares, and whose page is built from the approved run alone, checked against the
  A2UI 1.0 schema, with every figure it names served.
  """

  use ExUnit.Case, async: true

  alias AshEnterprise.Guides
  alias AshEnterprise.Guides.Schema
  alias AshEnterprise.Surfaces
  alias AshJourneys.{Info, L10n, Lock}

  defp locked do
    {:ok, lock} = Lock.read(File.cwd!())
    lock.journeys
  end

  defp journey(%{journey: {module, id}}), do: Info.ir(module, id)

  test "every approved journey has one guide, at /app/guide/<journey>, opened by /guide <journey>" do
    guides = Surfaces.guides()
    assert guides != []

    assert Enum.sort(Enum.map(guides, &Atom.to_string(elem(&1.journey, 1)))) ==
             Enum.sort(Map.keys(locked()))

    for %{journey: {_module, id}} = guide <- guides do
      assert guide.path == "/app/guide/#{id}"
      assert guide.acp.command == "guide #{id}"
      assert guide.renderer == :specialist
      assert {^guide, ""} = Surfaces.match_command("guide #{id}")
    end
  end

  test "a guide's label and blurb are its journey's title and goal, in every locale it declares" do
    for guide <- Surfaces.guides(), ir = journey(guide), locale <- ir["locales"] do
      {module, _id} = guide.journey
      backend = Info.gettext(module)

      {title, goal} =
        Gettext.with_locale(AshEnterpriseWeb.Gettext, locale, fn ->
          {Surfaces.translate(guide.label), Surfaces.translate(guide.blurb)}
        end)

      assert {:ok, ^title} = L10n.text(backend, ir["title"], %{}, locale)
      assert {:ok, ^goal} = L10n.text(backend, ir["goal"], %{}, locale)
    end
  end

  describe "a guide's page" do
    test "holds each numbered step, its figures and the outcome, in each locale" do
      for guide <- Surfaces.guides(), ir = journey(guide), locale <- ir["locales"] do
        assert {:ok, [message]} = Guides.messages(guide.journey, locale)
        assert Schema.validate([message]) == :ok

        components = message["createSurface"]["components"]

        # The browser refuses a component id that is not a UAX #31 identifier.
        for %{"id" => id} <- components,
            do: assert(id =~ ~r/\A[\p{L}\p{Nl}][\p{L}\p{Nl}\p{Mn}\p{Mc}\p{Nd}\p{Pc}]*\z/u)

        texts = for %{"component" => "Text", "text" => text} <- components, do: text

        for n <- 1..length(ir["steps"]),
            do: assert(Enum.any?(texts, &String.starts_with?(&1, "#{n}. ")))

        {:ok, outcome} =
          L10n.text(Info.gettext(elem(guide.journey, 0)), ir["outcome"], %{}, locale)

        assert List.last(texts) == outcome

        figures = for %{"component" => "Image", "url" => url} <- components, do: url
        declared = for step <- ir["steps"], %{"type" => "figure"} <- step["body"], do: step
        assert length(figures) == length(declared)

        for "/app/guide/figures/" <> file <- figures do
          [digest, "png"] = String.split(file, ".")
          assert {:ok, <<137, "PNG", _rest::binary>>} = Guides.figure(digest)
        end
      end
    end

    test "names its labels in the reader's locale" do
      guide = Surfaces.fetch!(:guide_revoke_a_leavers_access)
      {:ok, [en]} = Guides.messages(guide.journey, "en")
      {:ok, [fr]} = Guides.messages(guide.journey, "fr")

      assert JSON.encode!(en) =~ "**Deactivate**"
      assert JSON.encode!(fr) =~ "**Désactiver**"
    end

    test "is in the journey's first locale for a reader in one it does not declare" do
      guide = Surfaces.fetch!(:guide_revoke_a_leavers_access)
      assert Guides.messages(guide.journey, "de") == Guides.messages(guide.journey, "en")
    end

    test "is one message saying it cannot be shown for a journey with no approved run" do
      assert {:error, [_ | _]} =
               Guides.messages({AshEnterprise.Journeys.Offboarding, :none}, "en")

      [message] = Guides.surface({AshEnterprise.Journeys.Offboarding, :none}, locale: "en")
      assert Schema.validate([message]) == :ok
      assert JSON.encode!(message) =~ "This guide cannot be shown"
    end
  end

  test "the schema refuses a message the browser could not apply" do
    guide = Surfaces.fetch!(:guide_revoke_a_leavers_access)
    {:ok, [message]} = Guides.messages(guide.journey, "en")

    assert {:error, reason} = Schema.validate([%{message | "version" => "v1.0"}])
    assert reason =~ ~s(value should be "1.0")

    unknown =
      update_in(
        message,
        ["createSurface", "components"],
        &[%{"id" => "x", "component" => "Nope"} | &1]
      )

    assert {:error, _reason} = Schema.validate([unknown])
  end

  test "a figure the lock does not approve is not served" do
    assert Guides.figure(String.duplicate("0", 64)) == :error
  end
end
