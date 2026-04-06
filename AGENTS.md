# AGENTS.md

## Scope

These instructions apply to the entire repository unless a more specific `AGENTS.md` in a subdirectory overrides them.

## Repository Purpose

This repository is used to generate and revise scripts that will later run in a terminal environment without internet access. All code and guidance should assume an offline execution target.

## Core Working Rules

1. Prefer `R` as the primary language for data processing, analysis, joins, validation, and script generation in this repository.
2. When shell access is needed, prefer `PowerShell` over other shells.
3. Do not design solutions that depend on internet access, web APIs, online package downloads, or remote services at runtime.
4. Prefer solutions that work with local files, local catalogs, and reproducible paths.
5. Before relying on a variable name, field definition, or dataset structure, check the available variable catalogs in the OBMEP Dropbox data.

## Data And Validation Sources

Use the following locations as the default external references for development and validation:

- Main data root: `C:\Users\megaj\Globtalent Dropbox\OBMEP`
- Variable catalogs: `C:\Users\megaj\Globtalent Dropbox\OBMEP\Data\raw\Catalogos`
- Default mock/test data root: `C:\Users\megaj\Globtalent Dropbox\OBMEP\test`

If a task involves schema interpretation, dataset integration, or variable selection, consult the catalogs under `Data\raw\Catalogos` before finalizing the script.

## Validation Expectations

1. Whenever script validation is needed, validate against available mock or test data stored in the Dropbox OBMEP directories.
2. Prefer the default test area at `C:\Users\megaj\Globtalent Dropbox\OBMEP\test` unless the task clearly requires another mock dataset.
3. Treat validation on mock/test data as part of the task whenever a script is created, revised, or debugged and validation is feasible.
4. If full validation is not possible, state exactly what was checked, what data was used, and what remains unverified.

## Implementation Guidance

1. Keep scripts compatible with offline execution and local filesystem access.
2. Prefer explicit paths, clear input/output assumptions, and comments only where they materially clarify non-obvious logic.
3. Avoid introducing unnecessary dependencies, especially dependencies that are difficult to install in a locked-down terminal environment.
4. When proposing or generating shell commands, default to `PowerShell` syntax and conventions.
