# Smoker 61,035-Run Failure-Recalibration Checkpoint

Checkpoint date: 2026-08-27

## Outcome

The forensic audit assigns all 61,035 historical rows to either their original
non-failure classification or a causally resolved recalibration bucket. No row
remains causally unresolved. The detailed findings and confidence boundaries
are in `FINAL_FORENSIC_AUDIT_REPORT.md`.

The immutable historical totals remain:

- PASS: 18,398
- FAIL: 31,077
- UNAVAILABLE: 11,560
- Total: 61,035

The repository report received an editorial reconciliation on 2026-08-28 to
replace interim wording that said several cases remained inconclusive. The final
retry evidence had already resolved those cases; no result data, evidence bucket,
count, or archive was changed.

## Repository contents

- `analysis/bin/`: builders used to inventory, reconcile, and layer validated
  confirmation evidence onto the preserved historical summary.
- `config/plans/audit/`: exact confirmation plans admitted to the audit.
- `docs/evidence/61035_failure_recalibration/`: final report, pair-level
  evidence tables, prerequisite source mapping, and this manifest.

Generated 61,035-row overlays and test-result directories are evidence outputs,
not source files, and remain outside Git.

## Canonical generated artifact

Archive:

`/home/ray/Smoker/audit_archives/Smoker_61035_failure_recalibration_final_20260827.tar.gz`

- Size: 1,876,625 bytes
- SHA-256: `66bb1c0b36aa722a17be010bfba982d9b6065e5e83124ac184af5d9442c2e1f9`
- Members: 69 (including directory entries)

The archive contains the final post-prerequisite overlay, its count report,
final configuration and dependency pair-evidence tables, the audit report,
builders, and exact confirmation plans.

Compact review archive collection:

`/home/ray/Smoker/audit_archives/Smoker_compact_review_archives_through_20260826.tar.gz`

- Size: 9,622,827 bytes
- SHA-256: `f1700a6bd6afc08008901a9f34db774f300a578aba2bd4ca5ccdb412b4f9fbc5`
- Members: 74 compact batch-review archives

This second bundle preserves the available compact review archives for the
validated and intermediate confirmation runs without committing generated test
results to Git.

Canonical uncompressed overlay in the development evidence tree:

`analysis/61035_post_prerequisite_overlay_20260826_final/61035_failure_audit_post_prerequisite_overlay.csv`

## Supersession record

Directories whose names contain `batch5` through `batch13`, `safe_target`, or
dates before the `20260826_final` overlays are retained as intermediate audit
history. They are superseded for final interpretation; they must not be used in
place of the canonical post-prerequisite overlay identified above.

Completed confirmation batches remain immutable. Later validated control runs
supersede earlier target-confounded interpretations only through the overlay
builders and report.

## Historical exclusion (superseded)

At the original checkpoint, the development copy of `Run_Smoker.pl` changed the pre-test backup prompt from
the documented default of running a backup to a default that skips it. That is
a product-behavior decision outside this forensic checkpoint and conflicts with
`AGENTS.md` section 13.1, so it was not transferred or committed at that checkpoint.

As of 30 August 2026, this exclusion is superseded: AGENTS.md section 13.1,
the launcher, and the backup tests all require the default-N prompt
`Run pre-test backup? [y/N]`. Only explicit y/Y runs the backup. The formatted
documentation has now been synchronized with that existing approved behavior.

## Verification performed

- Every admitted confirmation batch passed structural validation and the
  independent result-classification audit.
- Configuration and dependency overlay regeneration produced byte-identical
  CSV and pair-evidence outputs.
- Final accounting preserved exactly 61,035 rows and the historical status
  totals above.
- The final evidence distribution sums to 61,035 with zero unclassified rows.
