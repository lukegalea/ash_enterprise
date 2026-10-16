defmodule AshEnterprise.SurfacesTest do
  @moduledoc """
  The surface registry (`AshEnterprise.Surfaces`) agrees with everything it
  claims to describe: the router serves each entry at its path with its
  LiveView, each UI module is over the entry's resource and declares its
  context, every ACP action exists — and the doors hold on both transports.
  """

  use AshEnterprise.DataCase, async: false

  import AshEnterprise.Test.DailyFixtures

  alias AshEnterprise.Acp.Commands
  alias AshEnterprise.Agents.Console
  alias AshEnterprise.Surfaces
  alias AshEnterprise.Surfaces.Doors
  alias AshEnterpriseWeb.A2ui

  describe "the registry" do
    test "keys and paths are unique, and every entry is grouped" do
      surfaces = Surfaces.all()
      group_keys = Enum.map(Surfaces.groups(), & &1.key)

      assert surfaces |> Enum.map(& &1.key) |> Enum.uniq() |> length() == length(surfaces)
      assert surfaces |> Enum.map(& &1.path) |> Enum.uniq() |> length() == length(surfaces)
      assert Enum.all?(surfaces, &(&1.group in group_keys))
      assert Enum.all?(surfaces, &(&1.door in [:signed_in, :operator, :compliance]))
    end

    test "the router serves every entry at its path, with its LiveView" do
      for surface <- Surfaces.all() do
        assert %{phoenix_live_view: {view, action, _opts, _session}} =
                 Phoenix.Router.route_info(AshEnterpriseWeb.Router, "GET", surface.path, "")

        assert view == surface.live, inspect(surface.key)
        if surface.live_action, do: assert(action == surface.live_action, inspect(surface.key))
        assert Surfaces.by_live(view, action) == surface
      end
    end

    test "every static /app page the router serves is in the registry (bar the launcher)" do
      routed =
        for %{path: "/app/" <> _ = path, metadata: %{phoenix_live_view: _}} <-
              Phoenix.Router.routes(AshEnterpriseWeb.Router),
            not String.contains?(path, ":"),
            do: path

      assert Enum.sort(routed) == Enum.sort(Enum.map(Surfaces.all(), & &1.path))
    end

    test "a UI module is over its entry's resource, and declares its context" do
      for %{ui: ui} = surface <- Surfaces.all(), ui do
        assert AshA2ui.Info.resource!(ui) == surface.resource, inspect(surface.key)

        if surface.context do
          assert surface.context in Enum.map(AshA2ui.Info.contexts(ui), & &1.name),
                 inspect(surface.key)
        end
      end
    end

    test "a record of a resource opens on the surface that declares a context for it" do
      # People first: a plain person link opens there. The golden-records
      # surface opens a person only when a link names it.
      assert [%{key: :people, context: :person}, %{key: :mdm_golden, context: :person}] =
               Surfaces.for_resource(AshEnterprise.Canonical.Person)

      assert %{key: :people} = Surfaces.record_surface(AshEnterprise.Canonical.Person)

      # Roles list but open no single record.
      assert [] = Surfaces.for_resource(AshEnterprise.Security.Role)

      # Two surfaces over conversations: each record lands on the one it matches.
      assert [%{key: :inbox}, %{key: :slack}] =
               Surfaces.for_resource(AshEnterprise.Canonical.Conversation)

      assert %{key: :slack} =
               Surfaces.record_surface(AshEnterprise.Canonical.Conversation, %{
                 external_system: "slack"
               })
    end

    test "every ACP action, and every command word, is real and unambiguous" do
      for %{action: {resource, action}} <- Surfaces.candidate_actions() do
        assert Ash.Resource.Info.action(resource, action), "#{inspect(resource)}.#{action}"
      end

      words = Enum.map(Surfaces.commands(), &elem(&1, 0))
      assert Enum.uniq(words) == words
      assert {%{key: :tasks}, ""} = Surfaces.match_command("my tasks")
      assert {%{key: :approvals}, ""} = Surfaces.match_command("tasks")
      assert {%{key: :calendar}, "week"} = Surfaces.match_command("calendar week")
      assert nil == Surfaces.match_command("calendars")
    end

    test "the palette is derived: palette commands, their verbs, then open and help" do
      names = Enum.map(Surfaces.candidate_actions(), & &1.name)

      assert ~w(today compose calendar inbox slack people approvals approve reject accounts
                sync erasure open help) == names
    end
  end

  describe "doors, on ACP" do
    setup do
      %{admin: tenant!(), operator: tenant!(operator?: true)}
    end

    test "any surface opens by its command, through Console.open", %{admin: admin} do
      assert {:ok, %{spec: spec, surface: {A2ui.UserUI, []}}} =
               Commands.route("users", admin.actor)

      assert {spec.resource, spec.action, spec.inputs} == {Console, :open, %{surface: "users"}}

      assert {:ok, %{surface: {A2ui.BusinessUnitUI, []}}} =
               Commands.route("open business units", admin.actor)

      # A hand-written page has no A2UI surface for the pane; the line says where it is.
      assert {:ok, %{spec: %{inputs: %{surface: "processes"}}, surface: nil}} =
               Commands.route("processes", admin.actor)

      assert {:ok, "Processes — " <> rest} =
               Console.open("processes", actor: admin.actor, tenant: admin.tenant)

      assert rest =~ "On the web: /app/processes"
    end

    test "a closed door refuses the command and the action alike", %{admin: admin} do
      refute Doors.open?(:operator, admin.actor)

      assert {:error, "Erasure scopes is for the platform operator."} =
               Commands.route("erasure", admin.actor)

      assert {:error, _} = Commands.open(:erasure, admin.actor)

      assert {:error, %Ash.Error.Forbidden{}} =
               Console.open("erasure", actor: admin.actor, tenant: admin.tenant)
    end

    test "the operator's door opens for the operator", %{operator: operator} do
      assert {:ok, %{spec: %{action: :scopes_digest}, surface: {A2ui.ErasureReadOnlyUI, []}}} =
               Commands.open(:erasure, operator.actor)
    end

    test "help lists the surfaces behind open doors only", %{admin: admin} do
      help = Commands.help(admin.actor)

      assert help =~ "Organization: users, teams, roles, business units"
      refute help =~ "erasure"
    end
  end
end
