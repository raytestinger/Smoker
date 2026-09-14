# Smoker Documentation Map

This directory contains the current technical documentation, validation reports,
and retained evidence supplied with Smoker.

## Suggested review path

For a first review of the project, read:

1. `Smoker_Project_Review_Brief.pdf` — review scope, principal claims, and a
   suggested path through the material.
2. `Overview.txt` / `Smoker_Overview_Reconciled.odt` — project purpose, operation,
   and overall structure.
3. `Smoker_Software_Design_Description_Reconciled.docx` — detailed architecture
   and implementation design.
4. `Smoker_61035_Final_Forensic_Audit_Report.md` — analysis and recalibration of
   the 61,035-case validation run.

The forensic audit is important when interpreting the large-run results. The
historical result set is preserved unchanged; subsequent confirmation experiments
provide a calibrated interpretation of the original failure classifications.

## 61,035-run audit release summary

The failure-recalibration audit is complete. All 61,035 historical rows have an
evidence assignment, all 156 historical configuration-failure dependency/version
pairs were tested across Perl 5.34, 5.36, 5.38, 5.40, and 5.42, and no row remains
causally unresolved. Deterministic overlay regeneration produced byte-identical
outputs. The immutable historical totals remain 18,398 PASS, 31,077 FAIL, and
11,560 UNAVAILABLE; the final report explains how later evidence changes the
interpretation of those results without rewriting them.

## Canonical documentation sources

* `Smoker_Overview_Reconciled.odt` — canonical overview.
* `Smoker_Software_Design_Description_Reconciled.docx` — canonical software
  design description.
* `Smoker_61035_Final_Forensic_Audit_Report.md` — final forensic audit of the
  61,035-case validation run.

## Audit builder maintenance

* `../analysis/README.md` — Perl builder interfaces, dependencies, and safe usage.
* `Perl_Audit_Builder_Conversion.md` — conversion comparisons and regression checks.

## Searchable text

* `Overview.txt` — searchable text representation of the overview.
* `Smoker_Software_Design_Description_Reconciled.txt` — searchable design description.

These text companions must agree with the canonical formatted documents.

## Derived convenience outputs

* `Smoker_Overview_Reconciled.pdf`
* `Smoker_Software_Design_Description_Reconciled.pdf`
* `Smoker_Project_Review_Brief.pdf`

These formats are provided for convenient viewing. They should not be edited as
the authoritative source.

## Documentation maintenance

When implementation or validated behavior changes:

1. Update the appropriate canonical source document.
2. Update its searchable text representation where applicable.
3. Regenerate derived PDF/image outputs.
4. Check cross-references and filenames.
5. Preserve historical reports rather than rewriting them to reflect later
   results.

Historical test results should remain immutable. Later findings should be recorded
as additional validation, confirmation, or recalibration evidence.
