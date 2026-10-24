---
description: Install the FastNim agent skill into the current project's .agents folder
---

Install the FastNim agent skill into the current working directory.

The bundled installer copies the `fastnim` skill (`SKILL.md` plus `references/`) into
`.agents/skills/fastnim/` and writes an `AGENTS.md` that points at it. When `.agents`
already exists the installer changes nothing and exits successfully.

1. Resolve the skill source directory (the folder that holds `SKILL.md` next to
   `references/`), in this order:
   - `$FASTNIM_SKILL_DIR`, when it is set and contains `SKILL.md`;
   - `../skills/fastnim` relative to this command file (the in-repo layout, i.e.
     `<fastnim-repo>/.kilo/skills/fastnim`);
   - otherwise ask the user for the FastNim checkout path.
2. Run the installer that ships inside that directory, with the current directory as the
   target:

   ```bash
   bash "<skill-source>/scripts/install.sh" "$PWD"
   ```

   `install.sh` takes the target directory as its first argument and defaults to the
   current directory. It exits with status 0 whether it installed the skill or found an
   existing `.agents` folder.
3. Report the installer output. If it reported that `.agents` already exists, say that
   nothing was changed and stop - do not create or edit files yourself.
