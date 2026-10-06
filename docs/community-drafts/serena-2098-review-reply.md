# Draft reply: oraios/serena PR #2098 (review by MischaPanch)

Status: DRAFT, not posted. Luke to review and post.

---

Good call, thanks. Done in 2664535d.

On startup, when the default pinned version is in use, Serena now hashes the installed Expert binary. If it matches one of the v0.1.0-rc.6 checksums (all five platforms), it logs a warning naming the path and sha, removes the `expert` resources dir, and downloads v0.1.10 as usual. If a user has set `expert_version` explicitly, their install is left alone, so pinning rc.6 on purpose won't cause a re-download on every start.

I went with the sha rather than the version string because the install dir isn't versioned and there's no version marker file from earlier installs, so the binary's checksum is the only reliable signal we have.

Added unit tests in `test/solidlsp/elixir/test_elixir_outdated_install.py` (outdated install removed and logged, current install kept, missing install is a no-op). They don't need Elixir or Expert.
