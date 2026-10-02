# Ash Enterprise tutorial

Livebook lessons 10-25, continuing [ash_tutorial](https://github.com/ash-project/ash_tutorial). The upstream series' lessons 0-9 live in that repo; this repo ships its own lesson 0 ([00_philosophy.livemd](00_philosophy.livemd)) and its numbered lessons start at 10. Start at 00_philosophy, then [overview.livemd](overview.livemd) — the overview has the one-time setup (Livebook, Postgres, the attached runtime) and the recipe for undoing the tutorial when you are done.

To read the notebooks, clone this repo and run `livebook server <checkout>/tutorial`, or open the `tutorial` directory from Livebook's open page. Opening the directory keeps the relative navigation links between lessons working; per-notebook import URLs break them.

Status: first draft. Lessons 10-13 and 17 run standalone; 14-25 run attached to an `ash_enterprise` dev node. Verify API calls in 15-24 lesson by lesson (`mix ash_agent.describe` is the authority).
