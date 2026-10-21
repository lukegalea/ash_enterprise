defmodule AshEnterpriseWeb.A2ui.FlightUI do
  @moduledoc """
  Flight view — one process run on the diagram it is executing, with a
  marker on the step it is standing on, moved as the engine advances.

  The run is the `:instance` context: selected by the deep link
  (`/app/r/flight/<id>`, which every "Where it stands" link in the app
  carries), and otherwise the newest running instance the reader may see.
  The diagram is `AshEnterprise.Process.FlightDiagram` (an adapter over
  `AshBpmn.FlightView`); the table lists the running instances the reader may
  see, each opening on its own flight view. A marker on a waiting step opens
  the task it waits on.

  Everything is read as the reader: someone who can read neither the run nor
  any of its tasks sees nothing of it, and a run's subject is named only as
  far as they may read it.

  Served at `/app/flights` and over ACP as `flight`.
  """

  use AshA2ui.Standalone

  a2ui do
    for_resource AshEnterprise.Bpmn.Instance
    surface_id "flight"
    title "Flight view"
    record_label "process run"

    context :instance do
      resource AshEnterprise.Bpmn.Instance
      picker false
    end

    diagram :flight do
      label "Where it stands"
      description "The run's process, with a marker on each step it is on now."
      source AshEnterprise.Process.FlightDiagram
    end

    # Rows open their own flight view (a page of its own: a run on another
    # process is another drawing), so the table selects no context.
    component :table do
      fields [:subject_label, :process_name, :stage_label, :started_label]
      read_action :running_now

      row_layout do
        title :subject_label
        meta [:process_name, :stage_label, :started_label]
        columns 2
      end
    end

    field :subject_label do
      label "Run"
      link {:flight, :id}
    end

    field :process_name do
      label "Process"
    end

    field :stage_label do
      label "Where it stands"
    end

    field :started_label do
      label "Started"
    end
  end
end

defmodule AshEnterpriseWeb.A2ui.BriefFlightUI do
  @moduledoc """
  Brief approvals in flight — the `morning.brief` process with a marker for
  every running brief the reader may see: composing, or waiting at "Approve
  the brief" for its owner. Each marker and row opens that run's flight view.

  Served at `/app/flights/briefs` and over ACP as `brief flight`.
  """

  use AshA2ui.Standalone

  a2ui do
    for_resource AshEnterprise.Bpmn.Instance
    surface_id "brief_flight"
    title "Brief approvals in flight"
    record_label "brief run"

    diagram :flight do
      label "Morning brief"
      description "Every running brief, on the step it is on now."
      source {AshEnterprise.Process.FlightDiagram, :process, ["morning.brief"]}
    end

    component :table do
      fields [:subject_label, :stage_label, :started_label]
      read_action :running_briefs

      row_layout do
        title :subject_label
        meta [:stage_label, :started_label]
        columns 2
      end
    end

    field :subject_label do
      label "Brief"
      link {:flight, :id}
    end

    field :stage_label do
      label "Where it stands"
    end

    field :started_label do
      label "Started"
    end
  end
end

defmodule AshEnterpriseWeb.A2ui.StewardFlightUI do
  @moduledoc """
  Stewardship in flight — the `mdm.steward_review` process with a marker for
  every match candidate under review that the reader may see, waiting at
  "Steward decision". Each marker and row opens that review's flight view;
  the decision itself is made on the steward queue.

  Served at `/app/flights/stewardship` and over ACP as `stewardship flight`.
  """

  use AshA2ui.Standalone

  a2ui do
    for_resource AshEnterprise.Bpmn.Instance
    surface_id "steward_flight"
    title "Stewardship in flight"
    record_label "steward review"

    diagram :flight do
      label "MDM steward review"
      description "Every review under way, on the step it is on now."
      source {AshEnterprise.Process.FlightDiagram, :process, ["mdm.steward_review"]}
    end

    component :table do
      fields [:subject_label, :stage_label, :started_label]
      read_action :running_steward_reviews

      row_layout do
        title :subject_label
        meta [:stage_label, :started_label]
        columns 2
      end
    end

    field :subject_label do
      label "Review"
      link {:flight, :id}
    end

    field :stage_label do
      label "Where it stands"
    end

    field :started_label do
      label "Started"
    end
  end
end
