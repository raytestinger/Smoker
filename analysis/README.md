# Retained-evidence analysis tools

The six audit builders are Perl programs. They require Perl, Text::CSV (already used by Smoker), and core modules including JSON::PP. Keep `analysis/lib/Smoker/AuditIO.pm` beside the `analysis/bin` directory. Python is not needed to run these builders or their regression tests. `reconcile_summary_results.pl` is unchanged.

These are historical-audit builders, not general validators: they retain the original batch names, expected counts, evidence selection and classification rules. They consume independently produced validation/classification evidence. They do not execute Docker or CPAN tests. Do not point outputs at completed batches or archived audit directories.

From the development root, use these interfaces (replace uppercase placeholders with paths):

```sh
perl analysis/bin/build_61035_configuration_overlay.pl --development ROOT --output NEW_DIRECTORY
perl analysis/bin/build_61035_dependency_overlay.pl --development ROOT --input-overlay CONFIGURATION_CSV --output NEW_DIRECTORY
perl analysis/bin/build_61035_other_failure_overlay.pl --development ROOT --input-overlay COMBINED_CSV --output NEW_DIRECTORY
perl analysis/bin/build_missing_prerequisite_frontier.pl --input-overlay FINAL_CSV --output NEW_DIRECTORY
perl analysis/bin/build_61035_missing_prerequisite_overlay.pl --input-overlay FINAL_CSV --batch CONFIRMATION_BATCH --sources SOURCES_CSV --output NEW_DIRECTORY
perl analysis/bin/build_failure_inventory.pl SUMMARY_CSV OUTPUT_DIRECTORY [AVAILABILITY_SUMMARY_CSV ...]
prove -v t/audit_builders.t
prove -lr t
```

The configuration builder reads `ROOT/analysis/61035_audit_20260823/61035_failure_audit.csv`. Each overlay's named CSV feeds the next stage. The frontier emits the 60-row confirmation plan and source mapping; the prerequisite overlay requires the independently completed confirmation batch, not just the generated plan. All five flagged builders support `--help` and reject an existing output directory. The inventory retains its original behavior of replacing its two named output files in an existing output directory.

CSV headers, field values, ordering, quoting, line endings, reports, and classification logic are preserved. Overlay CSVs use CRLF; inventory CSV uses LF. Evidence files are read only. Compact review packages omit the full retained batches, so historical regeneration requires the development evidence tree; the regression tests use disposable fixtures and are self-contained.

See `../docs/Perl_Audit_Builder_Conversion.md` for executed comparisons and limitations.
