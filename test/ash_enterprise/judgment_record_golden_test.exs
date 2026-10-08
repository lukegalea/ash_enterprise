defmodule AshEnterprise.JudgmentRecordGoldenTest do
  @moduledoc """
  Golden hashes for the frozen judgment-record artefacts.

  RFC S1-24 is **"ACCEPTED — v0 FROZEN"**: v0 never changes, so the bytes of
  the RFC text, the JSON Schema and every synthetic fixture are pinned here.
  Any drift — a thawing edit to the doc, a schema tweak without a v1, a
  fixture touched by accident — fails this suite. The only sanctioned way to
  change any of these files is a deliberate, reviewed re-pin of this table in
  the same commit.

  v1 (2026-10-05 freeze) extends the table without re-pinning anything v0:
  the frozen v1 text lands at `docs/rfc/judgment-record-v1.md` and the `1 − p`
  decimal fixture (RFC §4.3, A4) joins the fixture set. Per AC-3, the schema
  and every v0 fixture byte stay unchanged from v0.

  v2 (2026-10-08 freeze, S1-68) extends the table the same way: the frozen
  v2 text lands at `docs/rfc/judgment-record-v2.md` (the temporal field
  table, §7.4). v2 supersedes nothing — v1 remains the frozen contract of
  record for v1 implementations — so v0's and v1's pins and sentinels stay
  byte-untouched.
  """

  use ExUnit.Case, async: true

  @repo_root Path.expand(Path.join(["..", ".."]), __DIR__)

  # Relative path => sha256 over the file's exact bytes.
  @golden %{
    "docs/rfc/judgment-record-v0.md" =>
      "70eb819295e7f05f92d036b09dd2989f521dbbc3fc2e30dd72fa7e7d1051f160",
    "docs/rfc/judgment-record-v1.md" =>
      "69f0f3337a466b41cc6f96e299bed613f12cd983c4b59b8ad5788552238fd03a",
    "docs/rfc/judgment-record-v2.md" =>
      "06496522c42fdee8b45b10e2de2d012ed31d9522fb213603c1918c63d25fd337",
    "priv/judgment_record/schema.json" =>
      "79d4a08a08320e7895d508dd377063acb0087ed2dab2f6f08364ccec5c1b881b",
    "test/fixtures/judgment_record/README.md" =>
      "bfbf91ba3429d4ef0060d34946254e1cf8320b71066ddfa7286529aa22468ced",
    "test/fixtures/judgment_record/observation-cast-failed-erased.json" =>
      "7bdb29c7288af869b2528e84d418baea38e6fbca0aea8184fb3fa51bd5d4e844",
    "test/fixtures/judgment_record/observation-choice-live.json" =>
      "d58f47838aa9bd45e8db7284478969dcec069005cc3ca679117798375c44eae4",
    "test/fixtures/judgment_record/observation-evidence-shadow.json" =>
      "25fa25969057848244fd6d38b038cd5d1ebc515b4d872035680f49462220b195",
    "test/fixtures/judgment_record/observation-extraction-generative.json" =>
      "e80a2fe661df1f0467f56d36b58de532f4c604493105fd071bbcaa9ede7a6ec3",
    "test/fixtures/judgment_record/observation-noul-live.json" =>
      "94a99e9029b026c6f6d014476fe9e78e70ab5b7d268d61993f1ab06819b133de",
    "test/fixtures/judgment_record/observation-noul-1-minus-p.json" =>
      "1618c0db7debf0c3de281886b4ee5bea43febf3deba12422ebd1ebb5e8a8d34f",
    "test/fixtures/judgment_record/observation-score-eval.json" =>
      "6a55462cdb6d2b6edfcd47f36f329f4ae7fa87a0959d40a636f3e49f7668e653"
  }

  @rfc_doc Path.join(@repo_root, "docs/rfc/judgment-record-v0.md")
  @rfc_v1_doc Path.join(@repo_root, "docs/rfc/judgment-record-v1.md")
  @rfc_v2_doc Path.join(@repo_root, "docs/rfc/judgment-record-v2.md")

  describe "frozen bytes" do
    test "every pinned artefact is byte-identical to its frozen sha256" do
      for {relative, expected} <- @golden do
        absolute = Path.join(@repo_root, relative)
        assert File.exists?(absolute), "missing frozen artefact: #{relative}"

        actual =
          absolute
          |> File.read!()
          |> then(&:crypto.hash(:sha256, &1))
          |> Base.encode16(case: :lower)

        assert actual == expected,
               "#{relative} drifted from its frozen hash.\n" <>
                 "  frozen: #{expected}\n  actual: #{actual}\n" <>
                 "  v0 never changes: revert the edit, or re-pin deliberately in a v1 review."
      end
    end
  end

  describe "freeze sentinel" do
    test "the RFC still carries the frozen status header" do
      assert File.exists?(@rfc_doc)
      assert File.read!(@rfc_doc) =~ "ACCEPTED — v0 FROZEN"
    end

    test "the v1 RFC carries its frozen status header (v1 freeze, 2026-10-05)" do
      assert File.exists?(@rfc_v1_doc)
      assert File.read!(@rfc_v1_doc) =~ "v1 — FROZEN"
    end

    test "the v2 RFC carries its frozen status header (v2 freeze, 2026-10-08)" do
      assert File.exists?(@rfc_v2_doc)
      assert File.read!(@rfc_v2_doc) =~ "v2 — FROZEN"
    end
  end

  describe "fixture hygiene (RFC §9, AC-5)" do
    test "no fixture carries transport, credentials or document prose" do
      for relative <- Map.keys(@golden),
          String.contains?(relative, "test/fixtures/"),
          String.ends_with?(relative, ".json") do
        contents = File.read!(Path.join(@repo_root, relative))

        for forbidden <- ["base_url", "api_key", "authorization", "BEGIN", "https://"] do
          refute contents =~ forbidden,
                 "#{relative} must not contain #{inspect(forbidden)} (§9)"
        end
      end
    end
  end
end
