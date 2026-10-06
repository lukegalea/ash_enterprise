defmodule AshEnterprise.Ingestion.FixtureTap do
  @moduledoc """
  A Singer-style *deterministic* source: the calendar vertical's tap stand-in
  until the operator's real calendar OAuth lands (epic E4, ADR 0011).

  Emits the same RECORD/STATE byte stream on every invocation — three events,
  the same three every run. Landing upserts on `(external_system, external_id)`,
  so a second run refreshes the same rows in place: that is the idempotency
  proof, and `Projection.replay(:calendar)` on top of it is the determinism
  proof. There is no clock, no randomness, no environment read anywhere in the
  fixture; the `time_recorded` and STATE values are constants on purpose.

  The records model Google Calendar event payloads (`summary`, `start.dateTime`,
  `iCalUID`, attendee `email`/`displayName`) — the same shapes the real
  `tap-google-calendar` will emit, so the projector built on this fixture is
  the projector the real vertical will need. Deliberately synthetic: no real
  personal data, which is why the calendar vertical needs no Zones admission
  (ADR 0042) while Gmail/Slack do.

  Wired through pipeline config — `"fixture" => true` and no `"command"` —
  and `AshEnterprise.Ingestion.TapWorker` bypasses its runner for such
  pipelines, using this module's output verbatim:

      config :ash_enterprise, AshEnterprise.Ingestion,
        pipelines: %{
          "calendar_dev" => %{"fixture" => true, "external_system" => "calendar"}
        }
  """

  @time_recorded "2026-10-05T07:00:00Z"

  @output [
            # SCHEMA lines are ignored by the worker's parser but a real tap emits them;
            # keeping them exercises the same lenient parse the real tap will hit.
            ~s({"type": "SCHEMA", "stream": "events", "schema": {}, "key_properties": ["id"]}),
            ~s({"type": "RECORD", "stream": "events", "record": {"id": "evt_cal_001", "iCalUID": "evt_cal_001@fixture.local", "summary": "Weekly plan review", "start": {"dateTime": "2026-10-05T09:00:00Z"}, "end": {"dateTime": "2026-10-05T09:30:00Z"}, "location": "War room", "organizer": {"email": "admin@example.com", "displayName": "Operator"}, "attendees": [{"email": "admin@example.com", "displayName": "Operator"}]}, "time_recorded": "#{@time_recorded}"}),
            ~s({"type": "RECORD", "stream": "events", "record": {"id": "evt_cal_002", "iCalUID": "evt_cal_002@fixture.local", "summary": "Design review with Alice", "start": {"dateTime": "2026-10-06T14:00:00Z"}, "end": {"dateTime": "2026-10-06T15:00:00Z"}, "organizer": {"email": "alice@example.com", "displayName": "Alice Chen"}, "attendees": [{"email": "alice@example.com", "displayName": "Alice Chen"}, {"email": "admin@example.com", "displayName": "Operator"}]}, "time_recorded": "#{@time_recorded}"}),
            ~s({"type": "RECORD", "stream": "events", "record": {"id": "evt_cal_003", "iCalUID": "evt_cal_003@fixture.local", "summary": "Dentist", "start": {"dateTime": "2026-10-07T10:30:00Z"}, "end": {"dateTime": "2026-10-07T11:15:00Z"}, "location": "Dr. Molnar", "organizer": {"email": "admin@example.com"}}, "time_recorded": "#{@time_recorded}"}),
            ~s({"type": "STATE", "value": {"bookmarks": {"events": {"last_updated": "#{@time_recorded}"}}}})
          ]
          |> Enum.join("\n")
          |> Kernel.<>("\n")

  @doc """
  The fixture's Singer output: byte-identical on every call, three RECORD
  events on the "events" stream plus a final STATE.
  """
  @spec singer_output() :: String.t()
  def singer_output, do: @output
end
