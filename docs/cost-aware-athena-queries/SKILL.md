---
name: cost-aware-athena-queries
description: Design, review, debug, or execute AWS Athena queries and pipelines with explicit scan budgets, cheap semantic preflights, reusable staging, and controlled retries. Use whenever work may scan Athena data; do not use for purely local SQL with no metered execution.
---

# Cost-Aware Athena Queries

## Purpose

Treat Athena bytes scanned as a budgeted resource. Prove query logic as cheaply as
possible before a production scan, avoid reading the same raw data repeatedly, and
report total actual consumption—including failures and discarded runs.

This skill does not authorize AWS execution, retries, S3 writes, or cleanup beyond
the user's task. Preserve the user's scope and all ordinary mutation safeguards.

## Cost Gate

Before running any planned set of queries expected to scan more than **1 GB**:

1. List every data-scanning query and its purpose.
2. Estimate bytes scanned for each query and the aggregate.
3. Convert the aggregate to estimated cost using the account's applicable rate. If
   the rate is unavailable, state the assumed rate and label the result an estimate.
4. Ask for explicit user approval of that query set and aggregate budget.

Zero-scan metadata operations such as catalog inspection, `DESCRIBE`, and query-status
lookups do not require this cost approval. A general request to implement or run a
pipeline does not replace the cost gate.

Approval covers only the disclosed queries and budget. Stop and obtain a revised
approval before:

- an unplanned retry, even when the original query was approved;
- adding an audit or diagnostic scan;
- widening selected columns, partitions, joins, or source tables;
- exceeding the approved aggregate scan estimate.

If scan size is genuinely unknown, assume the 1 GB threshold may be exceeded and ask
before execution.

## Workflow

### 1. Establish the cheapest source of truth

- Inspect schemas, partitions, file sizes, prior query statistics, and existing
  narrow or local artifacts first.
- Prefer local parquet and DuckDB for logic that does not require the complete remote
  population.
- Do not infer that `LIMIT` makes a query cheap. Athena may still read whole files,
  row groups, or columns needed by the plan.

### 2. Prove semantics locally

Build fixtures for the behavior most likely to invalidate a production result,
including as applicable:

- null, blank, sentinel, malformed, and contradictory values;
- missing, reversed, and boundary dates;
- classifier precedence and explicit exclusion categories;
- duplicate keys and fan-out;
- provenance flags whose supporting value is null;
- output gates and retained/gained/lost membership.

Test observable invariants, not merely that generated SQL contains expected text.
Use engine-compatible shims where necessary, but document any behavior that cannot be
proved outside Athena.

### 3. Profile the decision boundary

Before joining large unrelated tables, run the smallest production-data query that
can expose classification mistakes. Project only the columns used by the decision,
then aggregate prospective inclusions and exclusions by reason and frequent raw
values.

Review at least:

- counts by decision route and boundary value;
- the largest raw-label groups admitted by a fallback;
- explicit negative categories that would be overridden;
- null-date and unusable-provenance cases;
- expected gains and losses if a prior population exists.

Include this profiler in the approved query budget when it may exceed 1 GB.

### 4. Plan scans as one reusable data flow

- Project only required columns and apply partition/predicate pruning as early as
  correctness permits.
- When classification will feed a build plus multiple audits, materialize one narrow
  classified stage and reuse it instead of rescanning the raw source.
- Derive comparison tables, summaries, and validation reports from the narrow stage
  or final output whenever possible.
- Persist enough reason/provenance fields to validate routes without returning to the
  raw table.
- Treat CTAS/UNLOAD staging as a deliberate output: name it, guard its destination,
  validate it, and include its write/read scans in the budget.

### 5. Execute once, then validate cheaply

Immediately before execution, recheck exact destinations and source assumptions.
Run only the approved query set. Validate row grain, nulls, key uniqueness, bounds,
route/year consistency, membership reconciliation, and protected-output checksums
using staged or final narrow data.

If a validation fails, do not automatically rerun the production query. First:

1. Record the failed query's ID and actual bytes scanned.
2. Determine whether the defect can be reproduced locally.
3. Use metadata or a narrowly projected diagnostic only if needed and budget it.
4. Correct and rerun local fixtures and the boundary profiler.
5. Present the revised production query and additional cost for approval.

Inspect partial Athena/S3 outputs before cleanup. Delete only verified failed-run
targets within the user's authorized scope, and report what was removed.

## Mandatory Current-Month Cost Tracker Refresh

For this user's Athena work, updating the private `AWS Monthly Costs 2026 YTD`
[Google Sheet](https://docs.google.com/spreadsheets/d/1u7heBbOYotCBsdp7e47cWr2lTv-YSKhcbkH-6aEMavE/edit)
is part of executing every query that scans data.

After each query reaches a terminal state, inspect its Athena execution metadata. If
`DataScannedInBytes > 0`, immediately refresh the Sheet even when the query failed,
was cancelled, diagnostic, or will be discarded:

1. Retrieve the complete month-to-date Athena execution metadata for workgroup
   `primary` in `us-east-2`, using zero-scan AWS CLI metadata calls.
2. Deduplicate by query ID and assign executions to dates and months after converting
   submission timestamps to `America/Sao_Paulo`.
3. Recompute the month-to-date bytes from the metadata. Never increment the prior
   Sheet value, and never add delayed Cost Explorer scan usage to the Athena total.
4. Refresh the applicable daily-detail row, its month-to-date total, and the latest
   month displayed in the Sheet. Estimate query cost as decimal GB scanned times the
   per-GB rate configured in the Sheet.
5. Preserve other AWS costs as Cost Explorer's billed total minus its billed Athena
   data-scan charge. Estimate total AWS cost as the live query estimate plus those
   other costs.

Metadata operations whose `DataScannedInBytes` is zero do not trigger a refresh. If
the applicable query month is absent or the Sheet cannot be updated, report the
unsynchronized query ID and scanned bytes immediately and do not treat the Athena
task as complete.

## Scan Ledger and Handoff

Maintain a per-query ledger with:

```text
query_id | purpose | status | estimated_bytes | actual_bytes | estimated_cost | disposition
```

Include successful, failed, cancelled, diagnostic, and discarded queries. At handoff,
report:

- the accepted run's scan volume and estimated cost;
- total actual scan volume and cost for the entire task;
- variance from the approved budget;
- any provisional or discarded scans separately;
- reusable staged outputs and whether they can prevent future raw rescans.

Do not describe only the final successful query when earlier attempts also incurred
cost.
