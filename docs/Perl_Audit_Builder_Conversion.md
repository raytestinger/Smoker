# Perl audit-builder conversion — 30 August 2026

Requested change: replace all six Python scripts in `analysis/bin` with Perl equivalents and test them. The existing `reconcile_summary_results.pl` is unchanged. Shared CSV, option and report utilities live in `analysis/lib/Smoker/AuditIO.pm`; independent regression expectations live in `t/audit_builders.t`.

## Executed checks

- All six programs and the shared module pass Perl syntax checks.
- All six Python originals and Perl replacements ran against the same retained development evidence, using the same absolute disposable output path sequentially. All 16 output files were byte-identical, without normalization. Comparisons include four 61,035-row overlays, pair evidence, frontier inventory and selected plan/source mapping, failure inventory, and reports.
- The final post-prerequisite overlay matches the archived SHA-256 `56587d70eb0752a7b565a149f8c6d62b1bd345294bbab39f2426b6b3ee6f29a0`.
- The independent Perl regression test passes 58 assertions: required arguments, multiline quoted Unicode CSV, literal zero values, failure grouping, latest eligible batch selection, exclusion of framework-only candidates, configuration retries, dependency classifications, explicit timeout evidence, baseline representative selection, prerequisite reproduction, rejected evidence, output protection, and input immutability.

- Full `prove -lr t` suite: **16 files, 851 tests, PASS**, both in development and in the compact review package. This includes the 58 new assertions. All three intermediate overlay CSVs also match their archived originals.
- Development and repository replacement files compare identical; the existing reconciliation script and historical evidence are unchanged. `git diff --check` passes.

## Scope and known inherited limitations

This is a language conversion, not a change to audit policy. Fixed historical batch names, counts, special-case dependency evidence and report wording remain as in the originals. In particular, the failure-inventory report contains an unconditional historical statement about absence of framework-error return codes; it must not be interpreted as validation of arbitrary new input. Correcting or generalizing that inherited report behavior is separate work.

No completed batch, original summary or archived overlay was modified. No live Docker/CPAN batch, backup or production release was run. Python originals and caches are preserved under `/home/ray/Smoker/cleanup_backups/20260830_perl_audit_conversion`, outside active `analysis/bin`. Historical records may still mention the original `.py` names. Current instructions and the canonical audit artifact inventory use `.pl`.

The comparison is evidence for retained inputs, not proof of equivalence for every malformed CSV or filesystem condition. Full regeneration needs the retained development evidence; only disposable-fixture regression tests are included in the compact review package.

## Compared output hashes

Report hashes include the disposable output path used for this comparison and may differ if another output path is used.

| Builder / file | SHA-256 (both implementations) |
|---|---|
| `build_61035_configuration_overlay/61035_failure_audit_configuration_overlay.csv` | `7992275778032318261d8646534a5c5bcfaa9e36a1271fe5eb7930d5ae07812c` |
| `build_61035_configuration_overlay/61035_failure_audit_configuration_overlay.txt` | `10914edf061d6cad2ddf45e9012bee258ab3211e879e2f4bc2c12315fa67b84d` |
| `build_61035_configuration_overlay/configuration_pair_evidence.csv` | `7f2d6ce4c0ce3e63b46ffbab201adecc36fe4065afd73814b50fb2a9414780c0` |
| `build_61035_dependency_overlay/61035_failure_audit_combined_overlay.csv` | `4471993e14334312fb708c647bf2f0d7f16301713e465e6043f80b70da781ebb` |
| `build_61035_dependency_overlay/61035_failure_audit_combined_overlay.txt` | `636db34dfbda58a406b40d126e24d928136245c845e92683922b80046c3b821e` |
| `build_61035_dependency_overlay/dependency_pair_evidence.csv` | `a04e7b547d5efba4351103951dd0e8fc2d965c626895f0b2e03e2b64c254a578` |
| `build_61035_other_failure_overlay/61035_failure_audit_final_overlay.csv` | `890a139a5318673975f333f3cacc9be38b2a4cad4ba92a1d108e447058c536ee` |
| `build_61035_other_failure_overlay/61035_failure_audit_final_overlay.txt` | `ce0f5249b4ecddc47be4e425f9cfbffb0354e5d5146a60b998f4eb5255588ef1` |
| `build_missing_prerequisite_frontier/60_missing_prerequisite_exact_confirmation.csv` | `7959acee97c7b6aa9ad8df00e0f7f362f53a0ba19dd329cf89a7dd2b817fca5a` |
| `build_missing_prerequisite_frontier/60_missing_prerequisite_exact_confirmation_sources.csv` | `66bdae2f339f7e6227d595a98337c3a2fae3a70b1a1846a6f545b8c6a9777e0e` |
| `build_missing_prerequisite_frontier/missing_prerequisite_frontier.txt` | `dba361827247fa0b39e5af1bd6be42e55fd778bf8c3ac5abeac9d90c4add0ad4` |
| `build_missing_prerequisite_frontier/missing_prerequisite_inventory.csv` | `85ca17443d3db248db10a445f8f1e74364faf4f7bc80df7ea179d3368b8460dc` |
| `build_61035_missing_prerequisite_overlay/61035_failure_audit_post_prerequisite_overlay.csv` | `56587d70eb0752a7b565a149f8c6d62b1bd345294bbab39f2426b6b3ee6f29a0` |
| `build_61035_missing_prerequisite_overlay/61035_failure_audit_post_prerequisite_overlay.txt` | `d20dee2fb036fbcc042859c1c3620487e502ed34a7b26a9ee466c6c5fa27cfe2` |
| `build_failure_inventory/failure_inventory.csv` | `0bd5bcc6afac149009896dc742cfc7e28bc2cf3b9e95e3841be041a4a8519885` |
| `build_failure_inventory/failure_inventory_report.txt` | `093004ac22d56cd4efa6ff1265e33f89df8b5e6825f335ac6048bab9d2f15ac2` |
