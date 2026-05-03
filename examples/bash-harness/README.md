# Bash Harness Example

A production-grade operator harness for Sandcastle using bash.

Copy this directory into your project as `.sandcastle/` and customise:
1. Set `PROJECT_TEST_CMD` in `.env` (your project's test runner command).
2. Set `SANDCASTLE_AUTO_GENERATED_FILES` in `.env` if your build regenerates
   any files that should always pass the allow-list gate.
3. Customise `Dockerfile` for your project's runtime dependencies
   (see the `PROJECT SETUP` comment block).
4. Rename `main.ts.example` to `main.ts` and fill in your docker image name.
5. Edit `prompt.md` (create one) to target your first issue.

See `OPERATOR.md` at the repository root for full operational documentation.
