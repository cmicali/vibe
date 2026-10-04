---
name: vibe-pr
description: How to write a Vibe pull request title and description — simple, clear English that says what the change does, its benefit, and why, with pros and cons, charted results, and screenshots where they apply. Use when opening a pull request, or writing or rewriting a PR title or description.
---

# Writing a pull request

Write the description in **simple, clear English** that someone outside the code can follow. Say plainly:

1. **What it does**: the change, in a sentence or two.
2. **The benefit**: what is better for the user or the codebase.
3. **Why**: the problem it solves, or the reason this approach was chosen.

Then, only where they apply:

- **Pros and cons**: a short list, when the change is a trade-off or there was a real alternative.
- **Results**: for performance, quality, or size work, show the numbers **clearly and simply**: a small before/after table, plus a chart. GitHub renders Mermaid, so a bar chart can go straight into the description:

  ````markdown
  ```mermaid
  xychart-beta
      title "Track open time (ms, lower is better)"
      x-axis ["Before", "After"]
      y-axis "ms" 0 --> 120
      bar [104, 38]
  ```
  ````

  Label the units and say which direction is better. Name what was measured and how (the benchmark or `make` target), in one line.
- **Screenshots**: for a new feature that can be seen, add screenshots of it in the running app, captured with the `vibe-debug` skill.

Keep it short. Leave out file-by-file narration, internal jargon, and anything the diff already shows. A reviewer should be able to read the description and know what changed, why it matters, and what it costs.

The title follows the repo's existing style: `area: What it does`, in the imperative (see `git log --oneline`).

Never name or credit the AI agent or tool that helped write the change (`AGENTS.md`, "No agent attribution").
