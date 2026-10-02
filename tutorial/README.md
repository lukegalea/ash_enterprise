# Ash Enterprise tutorial

Livebook lessons 1-25, self-contained. Lessons 1-9 fork the upstream [ash_tutorial](https://github.com/ash-project/ash_tutorial) lessons 1-9 (MIT — each forked file carries the SPDX attribution) and retarget them to the support-desk domain, so `Tutorial.Support.Ticket` and `Tutorial.Support.Representative` carry unchanged from lesson 4 to lesson 10. This repo also ships its own lesson 0 ([00_philosophy.livemd](00_philosophy.livemd)). Start at 00_philosophy, then [overview.livemd](overview.livemd) — the overview has the one-time setup (Livebook, Postgres, the attached runtime) and the recipe for undoing the tutorial when you are done.

To read the notebooks, clone this repo and run `livebook server <checkout>/tutorial`, or open the `tutorial` directory from Livebook's open page. Opening the directory keeps the relative navigation links between lessons working; per-notebook import URLs break them.

Status: first draft. Lessons 1-13 and 17 run standalone; 14-25 run attached to an `ash_enterprise` dev node. Verify API calls in 15-24 lesson by lesson (`mix ash_agent.describe` is the authority).
