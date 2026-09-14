# Smoker

Smoker is a Docker-based framework for reproducible testing of Perl modules under controlled dependency configurations. It grew out of discussions in the Chicago Perl Mongers group about the need for a standard CPAN module testbed, with substantial guidance and assistance from Doug Bell.

Each test executes in an isolated container and produces a permanent artifact directory containing logs and status information. The framework makes compatibility testing repeatable, inspectable, and easy to automate.

---

## Prerequisites

Smoker requires the following host tools:

* Host Perl v5.34 or later (validated on v5.34–v5.42)
* Docker (daemon running, accessible without sudo)
* cpanm
* CPAN::Mini (`minicpan`) — optional, for local mirror
* rsync — required for the maintainer tree-sync utility; optional for mirror restore and explicitly requested MiniCPAN backup
* bash

The automated test suite also requires `IO::Pty`, `Text::CSV`, and `Log::Log4perl`. Run `prove -lr t` from the project root. The release-pipeline tests require `git` and `rsync`; the suite uses disposable fixtures rather than a live CPAN batch.

Verify tools are available:

```bash
command -v docker perl cpanm bash
# Optional tools:
command -v minicpan rsync
docker ps
```

Install CPAN::Mini if needed:

```bash
cpanm CPAN::Mini
```
Note: user must be able to run Docker without sudo.

```bash
sudo usermod -aG docker $USER
```
Smoker was developed and validated on Linux Mint / Ubuntu-class Linux hosts.

---

## Quick Start

```bash
cd Smoker
scripts/run/16_tests.sh
```

Or invoke the launcher directly with a plan filename or explicit path:

```bash
perl Run_Smoker.pl config/plans/16_tests.csv
perl Run_Smoker.pl config/plans/9_sample.csv
perl Run_Smoker.pl config/plans/9_sample.csv --jobs 8
```
`--jobs N` runs up to **N** plan rows concurrently, each in its own Docker container.

For a review-sized, mostly reproducible example with retained compact output:

```bash
scripts/run/20_tests.sh
```

Its matching validated reference batch is under
`examples/test_results/20_tests_20260902_184920/`. The reference run used
Linux Mint 22.3, Perl image `perl:5.38`, six concurrent workers, and the plan
in `config/plans/20_tests.csv`.

Results are written to a timestamped batch directory:

```
test_results/16_tests_YYYYMMDD_HHMMSS/
```
## Resource Notes

Large runs can consume significant disk space.

Approximate artifacts:
- 4-test demo: tens of MB
- 200-test run: hundreds of MB
- 1000-test run: multiple GB depending on logs and build artifacts

---

## Local CPAN Mirror (Optional)

Smoker does **not** require a local CPAN mirror. By default, it uses live CPAN.

For large or repeated runs, you may create a local minicpan mirror:

```bash
bin/minicpan_ready.sh
```

This creates or updates the configured MiniCPAN mirror. By default it makes no
snapshot copy. Pass `--snapshot` to copy a successfully updated mirror to
`/Backup/minicpan`, or to `SMOKER_SAVE_MINICPAN` when that override is set.

After a valid local mirror exists, Smoker automatically uses it. If no usable local mirror is found, Smoker automatically falls back to live CPAN.

This keeps first-run testing simple while preserving a reproducible local mirror option for larger experiments.

---

## Execution Invariant

```
1 unique plan row  ->  1 run directory  ->  1 rc.code  ->  1 summary row
```

Validate after a run:

```bash
cd test_results/<batch>
echo "plan rows : $(( $(wc -l < summary.csv) - 1 ))"
echo "rc.code   : $(find runs -name rc.code | wc -l)"
```

Both numbers should be identical.

---

## Result Codes

| rc.code | Meaning |
|---|---|
| `0` | PASS |
| `111` | UNAVAILABLE (requested dependency version not found) |
| `125` | Framework failure: `status=FAIL`, `subtype=framework_error`, explicit framework evidence required |
| other non-zero | FAIL |

---

## Environment Variables

| Variable | Default | Purpose |
|---|---|---|
| `SMOKER_HOME` | auto-detected from script | Smoker install root |
| `SMOKER_ROOT` | same as `SMOKER_HOME` | Compatibility alias |
| `SMOKER_LOCAL_MIRROR` | auto-detected if usable | Optional local CPAN mirror |
| `SMOKER_TARBALL_CACHE` | `$SMOKER_HOME/.cpanm/smoker-dists` | cpanm tarball cache |
| `SMOKER_DEFAULT_JOBS` | `8` | Default parallel jobs |
| `SMOKER_SNAPSHOT_ROOT` | `/QuickBackup` | Backup destination root |

---

## Project Layout

```
Smoker/
  Run_Smoker.pl            Main entry point
  bin/
    run_plan_csv.pl        Scheduler CLI
    bksmoker.sh            Atomic backup to /QuickBackup/
    docker_cleanup.sh      Prune stopped containers
    minicpan_ready.sh      Build/update local CPAN mirror

  lib/Smoker/
    Runner.pm              Executes one plan row
    Scheduler.pm           Parallel dispatcher
    Docker.pm              Docker image builder
    Result.pm              Shared classification and finalization policy
    Inner.pm               Executes CPAN installation and testing in-container

  config/plans/
    16_tests.csv           16 tests covering 4 modules
    9_sample.csv           9 sample tests
    200_tests.csv          200 tests covering 50 modules
    1000_tests.csv         1000 tests covering 50 modules

  docs/
    README.md
    Smoker_Overview_Reconciled.odt
    Smoker_Software_Design_Description_Reconciled.docx
    Overview.txt
    Smoker_Overview_Reconciled.pdf

  Runtime-created directories:
    state/docker_images/
    test_results/
    minicpan/

  scripts/run/
    16_tests.sh            Shortcut → config/plans/16_tests.csv
    9_sample.sh            Shortcut → config/plans/9_sample.csv
    200_tests.sh           Shortcut → config/plans/200_tests.csv
    1000_tests.sh          Shortcut → config/plans/1000_tests.csv
```
---

## Plan CSV Format

Smoker accepts one canonical 8-column input-plan format:

```text
base,mode,module,version,dep_one,dep_one_version,dep_two,dep_two_version
```

| Column | Description |
|---|---|
| `base` | Perl Docker image (for example, `perl:5.38`) |
| `mode` | `baseline`, `vary-one`, or `vary-two` |
| `module` | Target CPAN module |
| `version` | Target module version (blank = latest) |
| `dep_one` | First dependency |
| `dep_one_version` | Selected version of `dep_one` |
| `dep_two` | Second dependency (`vary-two`) |
| `dep_two_version` | Selected version of `dep_two` |

The header names and order are required. Scheduling options such as parallel
job count are command-line or environment settings, not plan columns. Runtime
results and metadata belong in `summary.csv` and the per-run artifact directories.

Duplicate handling is CSV-aware. Unique-row identity is based on the complete
ordered set of parsed field values, so harmless quoting differences do not
create separate executions. In `vary-two` mode, the two dependency-version
tuples are an unordered pair, so reversing them does not create a second test.

### Test Modes

- **baseline** — install the target module with normal dependency resolution
- **vary-one** — fix one dependency to a specific version before installing
- **vary-two** — fix two dependencies simultaneously

---

## Output Layout

```text
test_results/
  sample_20260101_120000/
    summary.csv
    validation_evidence.txt
    logs/
      run_smoker.log
    runs/
      000001/
        build.log
        run.out
        run.err
        rc.code
        result.meta
        execution_trail.audit
        00_command.txt
        framework_error.evidence     # framework failures only
        reports/
          cpanm_work_build.log
          diag.txt
```
---

## Docker Image Caching

Smoker builds a custom Docker image (`smoker-inner:<sha1>`) for each
unique base image, installing the required build tools. The image is
fingerprinted by a SHA-1 of its `Dockerfile`, so rebuilds only happen
when the definition changes.

Built Dockerfiles are stored in `state/docker_images/`.

---

## Backup

```bash
bin/bksmoker.sh
```

Creates `/QuickBackup/Smoker_YYYY-MM-DD_HHMMSS.tar.gz`, or writes to
`SMOKER_SNAPSHOT_ROOT` when explicitly set. The archive is written
atomically (`.partial` temp file, then `mv`) so interrupted backups leave
no corrupt archive.

`Run_Smoker.pl` owns the interactive pre-run decision and asks
`Run pre-test backup? [y/N]`. Answer `y` to run it. Enter, `n`, timeout,
invalid input, and noninteractive execution skip the backup, which keeps
trial-and-error runs fast. Run `bin/bksmoker.sh` directly whenever an explicit
backup is wanted; it does not prompt.

The normal source archive uses `tar` and does not require `rsync`. `rsync` is
required only when `SMOKER_BACKUP_MINICPAN` explicitly requests copying the
MiniCPAN mirror.

Excluded from backup:

```text
bkSmoker/
test_results/
minicpan/
minicpan.incomplete/
.cpanm/
archive/
state/
tmp/
logs/
QuickBackup/
distribution/
*.tar
*.tar.gz
*.tgz
```

---

## Distribution

Generate the release tree only from a clean, committed repository:

```bash
bin/make_distribution.sh --dry-run
bin/make_distribution.sh
```

The builder exports the current Git commit into a staging directory and then
atomically replaces the sibling `distribution/` tree. Untracked files, test
results, caches, and other development artifacts cannot enter the release.
`RELEASE_SOURCE.txt` records the exact source commit.

`admin/sync_smoker_trees.sh` honors `SMOKER_DEVELOPMENT`,
`SMOKER_REPOSITORY`, and `SMOKER_DISTRIBUTION`. If synchronization changes
tracked repository files, distribution generation is deferred until those
changes are reviewed and committed.

---

## Validation

```bash
perl -Ilib -c Run_Smoker.pl
perl -Ilib -c lib/Smoker/Runner.pm
perl -Ilib -c lib/Smoker/Scheduler.pm
perl -Ilib -c lib/Smoker/Docker.pm
perl -Ilib -c lib/Smoker/Inner.pm
bash -n bin/bksmoker.sh
bash -n bin/minicpan_ready.sh
```

Safe local checks:

- Perl files report `syntax OK`
- Shell syntax checks produce no output

At the end of a normal batch, `Run_Smoker.pl` runs the independent validator
automatically. The validator writes `validation_evidence.txt` and reports:

```text
Expected execution paths
  Satisfied
  Unsatisfied

Required result files
  Complete
  Incomplete

Result classification
  Classified
  Unclassified
```

Validation derives integrity from the batch artifacts. Producer-written facts
do not certify their own correctness.
---

## Design Goals

- **Every test is reproducible** — isolated Docker containers, dependency-version control, optional local mirror

- **Every result is traceable** — 1:1 mapping from plan row to artifact directory

- **Every summary row has evidence** — `rc.code`, `result.meta`, `execution_trail.audit`, logs, and framework evidence when required

- **Interrupted scheduling remains accounted for** — orderly SIGINT/SIGTERM recovery finalizes active and pending unique rows as evidenced framework failures

- **Large summaries remain practical** — a batch-local run-id index is bootstrapped once for legacy summaries; ordinary first-time results then append under a stable lock, while missing or damaged transaction state, retry, and recovery use atomic reconciliation

- **Shutdown escalation is bounded** — scheduler groups receive a five-second TERM/INT grace period and then KILL; the launcher performs a blocking reap after KILL so it does not deliberately abandon a still-owned child (an uninterruptible kernel wait can therefore extend final reap time)
