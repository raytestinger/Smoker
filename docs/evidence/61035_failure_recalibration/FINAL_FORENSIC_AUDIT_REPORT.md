# Smoker 61,035-Run Failure-Recalibration Forensic Audit

## Executive conclusion

The historical 61,035-run Smoker batch is structurally usable as historical evidence, but its original top-level `FAIL` total must not be read as 31,077 currently reproducible module failures.

The audit preserved the historical results and overlaid subsequent experiments. All 61,035 rows now have either an original non-failure classification or a resolved causal recalibration bucket. No row remains causally unresolved.

The largest corrections are:

- 12,115 historical target-install/test failures involve target releases subsequently proven unavailable.
- 4,553 historical dependency-install failures belong to dependency/version pairs whose installation failure reproduced on all five tested Perl bases.
- 4,136 historical configuration failures belong to pairs whose configuration failure reproduced on all five bases.
- 1,341 historical failure rows belong to pairs that did not reproduce their original failure mechanism: 1,115 dependency-install rows and 226 configuration rows.
- 880 historical dependency-install failures refer to exact dependency releases subsequently confirmed unavailable.

These are pair-level evidence assignments. Except where explicitly stated, they do not mean that every historical row was individually rerun.

## Immutable source and method

The source batch was `61035_tests_20260812_020849`. Its historical `summary.csv` was not rewritten. Completed confirmation batches were not edited.

The audit proceeded in three layers:

1. Preserve the original row, status, return code, note, and taxonomy.
2. Require confirmation batches to pass both independent structural validation and result-classification audit.
3. Join experimental evidence to historical rows by the exact responsible module/version pair, while retaining explicit buckets for version-dependent, non-reproduced, target-confounded, sample-supported, and unresolved evidence.

Later dedicated control runs supersede earlier target-confounded runs. For example, the later Contract::Declare controls supersede target-related results for Data::YAML::Writer and Net::SockAddr. Batch selection uses recorded execution time rather than lexical directory ordering.

## Original 61,035-run results

| Historical status | Rows |
|---|---:|
| PASS | 18,398 |
| FAIL | 31,077 |
| UNAVAILABLE | 11,560 |
| **Total** | **61,035** |

Historical failure taxonomy:

| Taxonomy | Rows |
|---|---:|
| target_install_test_failed | 12,117 |
| dependency_install_failed | 6,673 |
| dependency_did_not_remain | 5,694 |
| configuration_failed | 5,420 |
| missing_prerequisite | 1,037 |
| other_fail | 135 |
| timeout | 1 |
| **Historical FAIL total** | **31,077** |

## Final evidence overlay

| Evidence bucket | Rows |
|---|---:|
| historical_pass | 18,398 |
| target_release_now_proven_unavailable | 12,141 |
| historical_unavailable | 11,560 |
| dependency_did_not_remain_sample_supported | 5,694 |
| dependency_install_failure_reproduced_all_bases | 4,553 |
| configuration_pair_reproduced_all_bases | 4,136 |
| configuration_pair_version_dependent | 1,014 |
| missing_prerequisite_mechanism_reproduced_all_bases | 1,037 |
| dependency_install_failure_not_reproduced | 1,115 |
| dependency_release_confirmed_unavailable | 880 |
| local_mirror_archive_failure_recalibrated | 75 |
| target_download_failure_reproduced_all_bases | 34 |
| dependency_pair_did_not_remain | 85 |
| dependency_pair_pass_or_did_not_remain | 40 |
| configuration_pair_not_reproduced | 226 |
| configuration_pair_mixed_failure_mechanism | 44 |
| target_failure_reproduced | 2 |
| timeout_supported_by_explicit_causal_state | 1 |
| **Total** | **61,035** |

## Target-release recalibration

The audit identified 254 known-unavailable target module/version pairs. They account for 16,751 historical `FAIL` rows in total, including 12,115 of the 12,117 target-install/test failures. The remaining two target-install/test rows, involving CaCORE, reproduced as supported `FAIL rc=1` results.

Therefore, the target-install/test bucket is effectively resolved as:

- 12,115 rows: target release subsequently proven unavailable.
- 2 rows: target failure reproduced.

This does not change the immutable historical status; it changes the correct interpretation of the evidence.

## Dependency-install recalibration

The 6,673 historical dependency-install failures cover 144 exact dependency/version pairs. All 144 pairs now have an evidence assignment.

| Dependency evidence | Rows | Pairs |
|---|---:|---:|
| Installation failure reproduced on all five bases | 4,553 | 71 |
| Original failure did not reproduce | 1,115 | 36 |
| Exact dependency release confirmed unavailable | 880 | 32 |
| Reproduced as “did not remain installed” | 85 | 4 |
| Role::Tiny split between PASS and “did not remain” | 40 | 1 |
| **Total** | **6,673** | **144** |

The six formerly inconclusive pairs were retested with the validated neutral target `Contract::Declare v1.0.0` across Perl 5.34, 5.36, 5.38, 5.40, and 5.42:

- Cache::Memcached v1.0.10 — 25 historical rows
- Class::Std::Fast v0.0.8 — 25
- Data::CompactReadonly v0.0.1 — 25
- Data::CompactReadonly v0.1.1 — 25
- Filesys::POSIX v0.9.19 — 30
- Test::Dependencies 0.01 — 10

All 30 safe-target controls passed with `rc=0`, and both structural validation and classification audit passed. The 140 historical rows therefore move to `dependency_install_failure_not_reproduced`. The label refers to the historical installation failure—not the dependency itself—failing to recur. The former 4,025-row `dependency_failure_unresolved` bucket and the later 140-row target-confounded bucket are both eliminated.

### File::Spec 3.00

Focused confirmation and a 365-row recalibration did not reproduce the historical dependency-install `rc=1` mechanism. Current results included PASS, UNAVAILABLE, module/target `rc=1`, and dependency-did-not-remain `rc=2`. File::Spec therefore remains a non-reproduced recalibration case, not a reproduced dependency-install failure.

### Role::Tiny 1.000000

The dedicated ten-row control produced five PASS results and five `FAIL rc=2` results stating that the requested version did not remain installed. It did not reproduce dependency-install `rc=1`. Its 40 historical rows have their own split-evidence bucket.

### Dedicated exception controls

Data::YAML::Writer v0.0.7 and Net::SockAddr v1.1.4 initially appeared to fail or be unavailable because their representative target modules failed first. Later five-base Contract::Declare controls passed, so the dependency-install mechanism did not reproduce. These later controls supersede the target-confounded runs for pair-level interpretation.

## Configuration-failure recalibration

The 5,420 historical configuration failures cover 156 exact dependency/version pairs. Thirteen 60-row confirmation batches tested all 156 pairs across Perl 5.34, 5.36, 5.38, 5.40, and 5.42.

| Configuration evidence | Rows | Pairs |
|---|---:|---:|
| Configuration failure reproduced on all five bases | 4,136 | 102 |
| Perl-version-dependent reproduction | 1,014 | 31 |
| Did not reproduce | 226 | 19 |
| Mixed failure mechanism across bases | 44 | 4 |
| **Total** | **5,420** | **156** |

Version-dependent pairs:

- JSON::XS 0.1 — three failures on Perl 5.38–5.42 and two passes on 5.34–5.36; 122 historical rows
- Crypt::SSLeay 0.72 — three failures on Perl 5.38–5.42 and two passes on 5.34–5.36; 57 rows

- Bit::Set::OO 0.13 — four failures, one pass; 68 historical rows
- Crypt::OpenSSL3::X509::Attribute 0.010 — four failures, one pass; 31 rows
- JSON::Schema::AsType::Draft7 v1.0.0 — four failures, one pass; 28 rows
- List::MoreUtils 0.04 — three failures, two passes; 129 rows
- MIME::Base64 2.00 — three failures, two passes; 183 rows
- String::CRC32 0.9 — three failures, two passes; 159 rows

Config::Model::SimpleUI 2.166 passed on all five bases, so its 25 historical configuration failures did not reproduce.

Confirmation batch four produced 54 configuration failures and six passes. Its failures had concrete causes, including Perl/XS incompatibilities, missing native libraries, a non-threaded Perl build, missing SWI-Prolog requirements, and explicit Perl-version gating. JSON::Schema::AsType::Draft7 correctly passed on Perl 5.42 because that release requires Perl 5.42.

Confirmation batch five prioritized the 12 highest-impact untested pairs, representing 726 historical rows. It produced 56 configuration failures and four passes. Ten pairs reproduced on all five bases. JSON::XS 0.1 and Crypt::SSLeay 0.72 each passed on Perl 5.34 and 5.36 but failed configuration on 5.38, 5.40, and 5.42, establishing version-dependent behavior.

Confirmation batch six covered the next 12 pairs, representing 300 historical rows. All 60 executions produced supported configuration failures, so all 12 pairs reproduced on every tested Perl base.

Confirmation batch seven covered 12 pairs representing 277 historical rows. Eight pairs reproduced configuration failure on all five bases; Protocol::Database::PostgreSQL::Backend::ErrorResponse 2.001 passed on all five bases; and Redmine::Stat 0.01 was version-dependent, passing on Perl 5.34/5.36 and failing configuration on 5.38–5.42. Two pairs were initially inconclusive: Wx::Perl::ListCtrl 0.03 had four configuration failures and one timeout, while WebService::Braintree::MultipleValuesNode 1.7 had three configuration failures and two generic installation failures.

Confirmation batch eight covered 12 pairs representing 238 historical rows. Eight pairs reproduced configuration failure across all five bases. Encode::IBM 0.11, Module::Starter::BuilderSet 1.82, and Perl::Critic::Policy::Lax::ProhibitComplexMappings::LinesNotStatements 0.014 passed on all five bases. Tk 804.036 was version-dependent, passing on Perl 5.34/5.36 and failing configuration on 5.38–5.42.

Confirmation batch nine covered 12 pairs representing 180 historical rows. Eight pairs reproduced configuration failure on all five bases. Data::Structure::Util 0.01, Heap::Simple::XS 0.01, and Object::Pad 0.01 were version-dependent, passing on Perl 5.34/5.36 and failing on 5.38–5.42. Chart::Plotly::Trace::Cone 0.042 passed on all five bases.

Confirmation batch ten covered 12 pairs representing 167 historical rows. XLog v1.0.0 reproduced on all five bases. Six pairs were version-dependent, and four passed on all five bases. Wx::Scintilla 0.39 was initially inconclusive after three configuration failures and two timeouts.

Confirmation batch eleven covered 12 pairs representing 97 historical rows. Image::BioChrome 1.16 and Image::Resize 0.01 reproduced on all five bases; five pairs were version-dependent; and Developer::Dashboard::PerlEnv 4.16 plus HTML::Parser 3.85 passed on all five bases. Three pairs were initially inconclusive because their five-base runs mixed configuration failures with generic installation failures.

Confirmation batch twelve covered 12 pairs representing 60 historical rows. Five pairs reproduced configuration failure on all five bases, while seven pairs passed on all five bases. No batch-twelve pair was version-dependent or inconclusive.

Confirmation batch thirteen covered the final 12 untested pairs, representing 43 historical rows. Five pairs reproduced configuration failure on all five bases, and seven were version-dependent. Consequently, every one of the 156 historical configuration-failure pairs has now been tested across all five Perl bases.

A final three-row retry replaced the timed-out results for Wx::Perl::ListCtrl 0.03 on Perl 5.42 and Wx::Scintilla 0.39 on Perl 5.36/5.42. With a longer timeout, all three produced supported configuration failures. Both pairs therefore reproduce on all five bases.

## Dependency-did-not-remain evidence

The historical bucket contains 5,694 rows. In the exact-history diagnostic sample, 18 of 20 reproduced as `FAIL rc=2`; one became `FAIL rc=1` and one timed out. This strongly supports the mechanism but is sample-level evidence, not proof that every one of the 5,694 rows remains reproducible.

Additional dependency-install confirmations moved 85 historical `rc=1` rows into a current “did not remain installed” interpretation, with Role::Tiny’s 40 rows retained separately because its dedicated control split five PASS and five `rc=2` results.

## Structural and classification integrity

Every batch admitted to the overlays passed:

- expected execution-path accounting;
- required result-file completeness;
- summary/run-directory consistency;
- independent result-classification audit.

Configuration confirmation batch four specifically had 60 unique plan rows, 60 run directories, 60 complete result sets, 60 classified rows, and 60 supported classifications. Its validator and final validator both exited zero.

The generated combined overlay was checked to preserve:

- exactly 61,035 data rows;
- 18,398 PASS, 31,077 FAIL, and 11,560 UNAVAILABLE historical statuses;
- all non-targeted evidence fields when adding each successive overlay;
- 5,420 configuration-failure rows across 156 pairs;
- 6,673 dependency-install rows across 144 pairs.

Deterministic regeneration produced byte-identical overlay and pair-evidence CSV files.

## Other-failure and timeout recalibration

The 135 historical `other_fail` rows reduce to three concrete mechanisms:

- 75 local MiniCPAN archive failures affecting Bio::AlignIO::selex, Bio::Chado::Schema::Result::Cv::CommonAncestorCvterm, and Bio::Tools::Primer3Redux::PrimerPair. Later validated archive-fallback controls passed across five bases, so these are retained as historical mirror/archive failures whose target installations later succeeded.
- 26 rows involving Bio::DB::BigWig 1.07 and Linux::InitFS::Entry 0.2, whose exact target releases were subsequently confirmed unavailable.
- 34 Alien::LibUSB 0.4 target-download failures. A later validated five-base batch reproduced the download failure, supporting the mechanism without establishing that the exact release is unavailable.

The single timeout, run 009756, is supported by explicit causal state: `subtype=timeout`, normalized `rc=8`, raw return code 124, and 1,805 seconds elapsed. It remains a genuine historical timeout rather than an unresolved generic failure.

## Missing-prerequisite recalibration

The 1,037 historical rows reduce to 12 prerequisite mechanisms. A 60-row exact-history frontier selected one representative per mechanism and Perl base. All 60 executions returned supported `FAIL rc=1` results and reproduced the same missing-prerequisite name as the historical row.

| Missing prerequisite | Historical rows |
|---|---:|
| ExtUtils::BuildRC | 517 |
| DBI | 185 |
| MD5 | 90 |
| ExtUtils::Depends | 50 |
| URI::Escape | 50 |
| Alien::Cowl | 30 |
| Module::Build::IkiWiki | 30 |
| IO::File::Cached | 25 |
| inc::Module::Install | 20 |
| ExtUtils::AutoInstall | 20 |
| Alien::wxWidgets | 15 |
| Alien::Base::ModuleBuild | 5 |
| **Total** | **1,037** |

This is mechanism-level evidence across all five bases, not an assertion that all 1,037 historical plan rows were individually rerun.

## Remaining loose ends

No rows remain without a resolved causal recalibration:

| Remaining bucket | Rows |
|---|---:|
| **Total** | **0** |

Recommended treatment:

Retain the resolved configuration, dependency, missing-prerequisite, `other_fail`, and timeout assignments unless a future audit requires direct reruns of every historical row.

## Confidence boundaries

- **Directly verified:** confirmation-run results, structural batch integrity, classification support, row counts, joins, and deterministic overlay generation.
- **Pair-level inference:** historical rows assigned evidence based on an exact dependency/version pair tested across five Perl bases.
- **Sample-supported:** the 5,694 historical dependency-did-not-remain rows.
- **Historical only:** original PASS and UNAVAILABLE rows not individually rerun for this audit.
- **Unresolved:** none.

No finding in this report rewrites what happened historically. The overlays provide a calibrated interpretation of which historical failures remain reproducible, were actually availability conditions, changed mechanism, or did not reproduce under the confirmation conditions.

## Appendix: Audit artifact inventory

- `analysis/61035_audit_20260823/61035_failure_audit.csv`
- `analysis/61035_configuration_overlay_20260825/61035_failure_audit_configuration_overlay.csv`
- `analysis/61035_configuration_overlay_20260825/configuration_pair_evidence.csv`
- `analysis/61035_combined_overlay_20260825/61035_failure_audit_combined_overlay.csv`
- `analysis/61035_combined_overlay_20260825/dependency_pair_evidence.csv`
- `analysis/61035_final_overlay_20260825/61035_failure_audit_final_overlay.csv`
- `analysis/61035_post_prerequisite_overlay_20260825/61035_failure_audit_post_prerequisite_overlay.csv`
- `analysis/61035_combined_overlay_20260825_safe_target/61035_failure_audit_combined_overlay.csv`
- `analysis/61035_combined_overlay_20260825_safe_target/dependency_pair_evidence.csv`
- `analysis/61035_post_prerequisite_overlay_20260825_safe_target/61035_failure_audit_post_prerequisite_overlay.csv`
- `analysis/61035_dependency_safe_target_frontier_20260825/30_dependency_safe_target_confirmation.csv`
- `analysis/61035_configuration_frontier_20260825/60_configuration_failure_confirmation_5.csv`
- `analysis/61035_configuration_overlay_20260825_batch5/61035_failure_audit_configuration_overlay.csv`
- `analysis/61035_combined_overlay_20260825_batch5/61035_failure_audit_combined_overlay.csv`
- `analysis/61035_post_prerequisite_overlay_20260825_batch5/61035_failure_audit_post_prerequisite_overlay.csv`
- `analysis/61035_configuration_frontier_20260825/60_configuration_failure_confirmation_6.csv`
- `analysis/61035_configuration_overlay_20260825_batch6/61035_failure_audit_configuration_overlay.csv`
- `analysis/61035_combined_overlay_20260825_batch6/61035_failure_audit_combined_overlay.csv`
- `analysis/61035_post_prerequisite_overlay_20260825_batch6/61035_failure_audit_post_prerequisite_overlay.csv`
- `analysis/61035_configuration_frontier_20260825/60_configuration_failure_confirmation_7.csv`
- `analysis/61035_configuration_overlay_20260826_batch7/61035_failure_audit_configuration_overlay.csv`
- `analysis/61035_combined_overlay_20260826_batch7/61035_failure_audit_combined_overlay.csv`
- `analysis/61035_post_prerequisite_overlay_20260826_batch7/61035_failure_audit_post_prerequisite_overlay.csv`
- `analysis/61035_configuration_frontier_20260826/60_configuration_failure_confirmation_8.csv`
- `analysis/61035_configuration_overlay_20260826_batch8/61035_failure_audit_configuration_overlay.csv`
- `analysis/61035_combined_overlay_20260826_batch8/61035_failure_audit_combined_overlay.csv`
- `analysis/61035_post_prerequisite_overlay_20260826_batch8/61035_failure_audit_post_prerequisite_overlay.csv`
- `analysis/61035_configuration_frontier_20260826/60_configuration_failure_confirmation_9.csv`
- `analysis/61035_configuration_overlay_20260826_batch9/61035_failure_audit_configuration_overlay.csv`
- `analysis/61035_combined_overlay_20260826_batch9/61035_failure_audit_combined_overlay.csv`
- `analysis/61035_post_prerequisite_overlay_20260826_batch9/61035_failure_audit_post_prerequisite_overlay.csv`
- `analysis/61035_configuration_frontier_20260826/60_configuration_failure_confirmation_10.csv`
- `analysis/61035_configuration_overlay_20260826_batch10/61035_failure_audit_configuration_overlay.csv`
- `analysis/61035_combined_overlay_20260826_batch10/61035_failure_audit_combined_overlay.csv`
- `analysis/61035_post_prerequisite_overlay_20260826_batch10/61035_failure_audit_post_prerequisite_overlay.csv`
- `analysis/61035_configuration_frontier_20260826/60_configuration_failure_confirmation_11.csv`
- `analysis/61035_configuration_overlay_20260826_batch11/61035_failure_audit_configuration_overlay.csv`
- `analysis/61035_combined_overlay_20260826_batch11/61035_failure_audit_combined_overlay.csv`
- `analysis/61035_post_prerequisite_overlay_20260826_batch11/61035_failure_audit_post_prerequisite_overlay.csv`
- `analysis/61035_configuration_frontier_20260826/60_configuration_failure_confirmation_12.csv`
- `analysis/61035_configuration_overlay_20260826_batch12/61035_failure_audit_configuration_overlay.csv`
- `analysis/61035_combined_overlay_20260826_batch12/61035_failure_audit_combined_overlay.csv`
- `analysis/61035_post_prerequisite_overlay_20260826_batch12/61035_failure_audit_post_prerequisite_overlay.csv`
- `analysis/61035_configuration_frontier_20260826/60_configuration_failure_confirmation_13.csv`
- `analysis/61035_configuration_overlay_20260826_batch13/61035_failure_audit_configuration_overlay.csv`
- `analysis/61035_combined_overlay_20260826_batch13/61035_failure_audit_combined_overlay.csv`
- `analysis/61035_post_prerequisite_overlay_20260826_batch13/61035_failure_audit_post_prerequisite_overlay.csv`
- `analysis/61035_configuration_frontier_20260826/3_configuration_timeout_retry.csv`
- `analysis/61035_configuration_overlay_20260826_final/61035_failure_audit_configuration_overlay.csv`
- `analysis/61035_combined_overlay_20260826_final/61035_failure_audit_combined_overlay.csv`
- `analysis/61035_post_prerequisite_overlay_20260826_final/61035_failure_audit_post_prerequisite_overlay.csv`
- `analysis/bin/build_61035_configuration_overlay.py`
- `analysis/bin/build_61035_dependency_overlay.py`
- `analysis/bin/build_61035_other_failure_overlay.py`
- `analysis/bin/build_61035_missing_prerequisite_overlay.py`
