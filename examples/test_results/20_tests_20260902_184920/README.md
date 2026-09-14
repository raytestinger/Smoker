# Validated 20-row example batch

This directory contains compact evidence from an actual Smoker run completed
on 2 September 2026. It was produced by:

```bash
scripts/run/20_tests.sh
```

The wrapper executes `config/plans/20_tests.csv`. That plan contains 20 unique
rows: eight baseline, eight vary-one, and four vary-two executions, all using
the `perl:5.38` Docker image.

The retained `summary.csv` has 20 data rows. All 20 executions completed with
`status=PASS` and `rc=0`. The independent validator reported:

- 20 original plan rows;
- 20 unique plan rows;
- 0 duplicate rows;
- 20 satisfied expected execution paths;
- 20 complete required result-file sets;
- 20 classified results;
- 0 unclassified results.

To keep the example small, this directory retains the batch plan and summary,
validator and review reports, scheduler log, and each run's `rc.code` and
`result.meta`. Full per-run build logs and CPAN work directories are excluded.
The paths and timestamps in the retained files are the original execution
records and have not been rewritten for portability.
