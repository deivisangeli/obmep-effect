# AGENTS.md

## Scope

These instructions apply to the entire repository unless a more specific `AGENTS.md` in a subdirectory overrides them.

## Repository Purpose

This repository holds two distinct kinds of code, and the applicable rules differ between them.

1. **SEDAP-bound scripts** (`scripts_sedap/`) are generated here and later run inside the SEDAP secure terminal, which has **no internet access**. These must assume an offline execution target.
2. **Local prep pipelines** (`prep/`) run on this machine against Dropbox data and external services. These **may** use the network, and some exist precisely to do so.

Before applying any rule below, establish which of the two you are working on. See **Execution Environments**.

## Execution Environments

| Area | Runs where | Network | Sent to SEDAP |
|---|---|---|---|
| `scripts_sedap/enviar/`, `scripts_sedap/extraidos/` | SEDAP secure terminal | **No** | Yes |
| `prep/`, including `prep/building_external_data/` | This machine (local) | **Yes** — CRAN, S3, Athena | **No** |

`prep/building_external_data/` is a deliberate, documented exception to the offline rule: it is a
**local, online** pipeline that installs packages from CRAN, uploads parquet to S3
(`revelio-misc`, `us-east-2`) and registers external tables in Athena (`revelio_database`).

- Do **not** copy anything from `prep/building_external_data/` into `scripts_sedap/`, and do not
  attempt to run it inside SEDAP — it would fail on the first network call.
- Its outputs are **external data products** consumed from Athena, not SEDAP deliverables.
- See `prep/building_external_data/README.md` for the process, measured results, and two
  non-obvious pitfalls that must not be reintroduced.

## Core Working Rules

1. Prefer `R` as the primary language for data processing, analysis, joins, validation, and script generation in this repository.
2. When shell access is needed, prefer `PowerShell` over other shells.
3. For **SEDAP-bound** scripts, do not design solutions that depend on internet access, web APIs, online package downloads, or remote services at runtime. Local `prep/` pipelines may use the network when that is their stated purpose; say so explicitly in the script header.
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

1. Keep **SEDAP-bound** scripts compatible with offline execution and local filesystem access. Local `prep/` pipelines that require the network must declare that dependency in a header comment and must not be sent to SEDAP.
2. Prefer explicit paths, clear input/output assumptions, and comments only where they materially clarify non-obvious logic.
3. Avoid introducing unnecessary dependencies, especially dependencies that are difficult to install in a locked-down terminal environment.
4. Do not create new functions or helper utilities unless explicitly requested; keep code simple and prefer existing functions from base R or the packages already in use.
5. When proposing or generating shell commands, default to `PowerShell` syntax and conventions.
