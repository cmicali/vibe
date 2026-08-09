---
description: Clean up comments — cut to essentials, drop historical and obvious ones
---

If `$ARGUMENTS` is non-empty, use it as the focus area. Otherwise, ask the user what to focus on using the AskUserQuestion tool with the options "Whole codebase" and "Working Changes" (the user can pick "Other" to fill in their own).

Then:

Clean up all the comments in the code base. Focus on the chosen focus area. Try to cut them down to the essentials: don't document things relating to how things were done in the past, and don't document things that are self-documenting or obvious. Be terse, use active voice.
