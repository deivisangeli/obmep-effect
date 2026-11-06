# Archived legacy cohort pipeline

This directory freezes the pre-degree-duration cohort entrypoints that were
retired on 2026-09-16. They are retained for provenance and historical replay;
they are not part of the active pipeline.

The active scripts in `prep/building_external_data/` now use the former
degree-duration definition as the canonical cohort. Historical remote S3 and
Athena names were not renamed or mutated. Any archived replay must therefore
use an isolated output namespace and must not publish over active products.

The matching Dropbox archive is:

`Data/intermediate/revelio_br_cohort/archive/legacy_cohorts/pre_degree_duration_20260916/`

Its `archive_manifest.csv` records the original and archived paths, object
type, byte size, and modification time for the moved top-level products.
