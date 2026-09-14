#!/usr/bin/env perl
use strict;
use warnings;

use FindBin;
use Cwd qw(abs_path);
use File::Basename qw(basename);
use File::Path qw(make_path);
use File::Copy qw(copy);
use Fcntl qw(:flock);
use IO::Select;

use lib "$FindBin::Bin/lib";
use Smoker::PlanCSV qw(deduplicate_csv_preserving_comments);

# -------------------------------------------------------------------
# Smoker home / confless startup
# -------------------------------------------------------------------
# Run_Smoker.pl is the top-level launcher. Therefore, the directory
# containing this script is the Smoker installation directory.
#
# No smoker.conf is required. Run_Smoker.pl discovers the installation
# directory, sets sensible defaults, and exports environment variables
# for the rest of the pipeline.
#
# A shared MiniCPAN mirror may exist outside the installation tree at:
#
#   $HOME/Smoker/minicpan
#
# Development, repository, and distribution trees can share that mirror.
# It is used only when its modules/02packages.details.txt.gz index exists.
#
# Run_Smoker.pl never creates or updates the MiniCPAN mirror. To create or
# update it explicitly, run:
#
#   bin/minicpan_ready.sh
#
# When no valid local mirror exists, Smoker uses live CPAN.
#
# Other machine-local settings may still be supplied through environment
# variables where appropriate.
# -------------------------------------------------------------------

my $smoker_home = abs_path($FindBin::Bin)
    or die "ERROR: cannot resolve Smoker home from $FindBin::Bin\n";

$ENV{SMOKER_HOME} = $smoker_home;
$ENV{SMOKER_ROOT} = $smoker_home;    # compatibility alias for older scripts

# -------------------------------------------------------------------
# Optional shared MiniCPAN mirror
# -------------------------------------------------------------------
# Respect an explicitly supplied SMOKER_LOCAL_MIRROR when it has a valid
# package index. Otherwise, check the standard shared location.
#
# If neither location contains a valid index, remove the variable so the
# runner falls back to live CPAN.
# -------------------------------------------------------------------

my $requested_mirror = $ENV{SMOKER_LOCAL_MIRROR};
my $shared_mirror    = "$ENV{HOME}/Smoker/minicpan";
my $selected_mirror;

if (
    defined $requested_mirror
    && length $requested_mirror
    && -f "$requested_mirror/modules/02packages.details.txt.gz"
) {
    $selected_mirror = $requested_mirror;
}
elsif (-f "$shared_mirror/modules/02packages.details.txt.gz") {
    $selected_mirror = $shared_mirror;
}

if (defined $selected_mirror) {
    $ENV{SMOKER_LOCAL_MIRROR} = $selected_mirror;
}
else {
    delete $ENV{SMOKER_LOCAL_MIRROR};
}

# Installation-relative tarball cache. Use a Smoker-only cache root so
# stale root-owned paths left by earlier container runs cannot block writes.
#
# Older shells and startup files may still export the legacy shared cache:
#
#   $HOME/.cpanm/dists
#
# Treat that exact legacy value as obsolete and replace it. A different,
# deliberately supplied SMOKER_TARBALL_CACHE value is still honored after
# the writability check below.
my $default_tarball_cache = "$smoker_home/.cpanm/smoker-dists";
my $legacy_tarball_cache  = "$ENV{HOME}/.cpanm/dists";
my $configured_cache      = $ENV{SMOKER_TARBALL_CACHE};

if (
    !defined($configured_cache)
    || !length($configured_cache)
    || $configured_cache eq $legacy_tarball_cache
) {
    if (defined($configured_cache) && $configured_cache eq $legacy_tarball_cache) {
        warn "WARN: ignoring legacy SMOKER_TARBALL_CACHE=$legacy_tarball_cache; "
            . "using $default_tarball_cache\n";
    }

    $ENV{SMOKER_TARBALL_CACHE} = $default_tarball_cache;
}

# Machine-local defaults.
# Users may override these from the shell before running Smoker.
$ENV{SMOKER_SAVE_MINICPAN} ||= "/Backup/minicpan";
$ENV{SMOKER_DEFAULT_JOBS}       ||= 8;
$ENV{SMOKER_RUN_TIMEOUT}        ||= 1800;
$ENV{SMOKER_BUILD_LOG_MAX_BYTES} ||= 100 * 1024 * 1024;

my $plan = shift @ARGV
    or die "ERROR: usage: Run_Smoker.pl <PLAN.csv | plan_name> [scheduler options]\n";

# Remaining command-line arguments, such as --jobs 8, are passed
# through to bin/run_plan_csv.pl.
#
# SMOKER_DEFAULT_JOBS is exported for scripts that want a default.
# If the user gives --jobs on the command line, that explicit value wins
# because it is passed directly to the scheduler.
my @scheduler_args = @ARGV;

# -------------------------------------------------------------------
# Resolve plan path
# -------------------------------------------------------------------

my $plan_path;

if ($plan =~ m{^/} && -f $plan) {
    $plan_path = $plan;
}
elsif (-f $plan) {
    $plan_path = $plan;
}
elsif (-f "$smoker_home/config/plans/$plan") {
    $plan_path = "$smoker_home/config/plans/$plan";
}
elsif (-f "$smoker_home/config/plans/$plan.csv") {
    $plan_path = "$smoker_home/config/plans/$plan.csv";
}
elsif (-f "$smoker_home/$plan") {
    $plan_path = "$smoker_home/$plan";
}
else {
    die "ERROR: plan CSV not found for input: $plan\n";
}

$plan_path = abs_path($plan_path)
    or die "ERROR: cannot resolve plan path: $plan\n";

# -------------------------------------------------------------------
# Batch naming
# -------------------------------------------------------------------

my $batch = basename($plan_path);
$batch =~ s/\.csv$//;

my $timestamp = timestamp();
$batch .= "_$timestamp";

# -------------------------------------------------------------------
# Output layout
# -------------------------------------------------------------------

my $suite_root = "$smoker_home/test_results/$batch";
my $runs_dir   = "$suite_root/runs";
my $logs_dir   = "$suite_root/logs";
my $analysis   = "$suite_root/analysis/traits";

make_path($runs_dir);
make_path($logs_dir);
make_path($analysis);
prepare_tarball_cache(
    requested   => $ENV{SMOKER_TARBALL_CACHE},
    fallback    => "$smoker_home/.cpanm/smoker-dists-$<",
);

# Prevent two launcher instances created in the same timestamp second from
# preparing or executing the same suite directory concurrently.
my $launcher_lock_path = "$suite_root/.launcher.lock";
open my $launcher_lock_fh, '>>', $launcher_lock_path
    or die "ERROR: cannot open launcher lock $launcher_lock_path: $!\n";
unless (flock($launcher_lock_fh, LOCK_EX | LOCK_NB)) {
    die "ERROR: another Run_Smoker.pl instance is already using $suite_root\n";
}
seek($launcher_lock_fh, 0, 0);
truncate($launcher_lock_fh, 0);
print {$launcher_lock_fh} "pid=$$ started=" . scalar(localtime()) . "\n";

my $run_log            = "$logs_dir/run_smoker.log";
my $original_plan      = "$suite_root/original_plan.csv";
my $deduplicated_plan  = "$suite_root/plan_deduplicated.csv";
my $skipped_duplicates = "$suite_root/skipped_dup.csv";
my $batch_info         = "$suite_root/batch_info.txt";
my $validation_report  = "$suite_root/validation_evidence.txt";
my $classification_report = "$suite_root/result_classification_audit.txt";
my $batch_review       = "$suite_root/batch_review.txt";
my $review_utility     = "$smoker_home/bin/nonpass_cpanm_logs.pl";
my $archive_utility    = "$smoker_home/bin/make_review_archive.sh";
my $review_archive     = "$suite_root/${batch}_review.tar.gz";

my $run_completed_normally = 0;
my $review_written         = 0;
my $validation_failed      = 0;
my $abort_reason           = '';
my $scheduler_pid;

$SIG{INT} = sub {
    $abort_reason = 'received SIGINT';
    stop_scheduler_group($scheduler_pid, 'INT') if $scheduler_pid;
    exit 130;
};

$SIG{TERM} = sub {
    $abort_reason = 'received SIGTERM';
    stop_scheduler_group($scheduler_pid, 'TERM') if $scheduler_pid;
    exit 143;
};

END {
    return if $run_completed_normally;
    return unless defined $suite_root && length $suite_root;

    if (!$review_written && -f "$suite_root/summary.csv") {
        generate_batch_review(
            utility   => $review_utility,
            batch_dir => $suite_root,
            output    => $batch_review,
            quiet     => 1,
        );
    }

    append_aborted_notice(
        output => $batch_review,
        reason => (
            length $abort_reason
            ? $abort_reason
            : 'Run_Smoker.pl exited before normal completion'
        ),
    );
}

# -------------------------------------------------------------------
# Preserve and deduplicate the plan
# -------------------------------------------------------------------

copy($plan_path, $original_plan)
    or die "ERROR: cannot copy plan to $original_plan: $!\n";

my ($input_rows, $unique_rows, $duplicate_rows) = deduplicate_plan(
    source_path     => $plan_path,
    output_path     => $deduplicated_plan,
    duplicates_path => $skipped_duplicates,
);

# The scheduler must receive only unique rows. The requested plan remains
# untouched, and the suite directory contains both the original input and
# the exact deduplicated plan that was executed.
my $executed_plan_path = $deduplicated_plan;

write_batch_info(
    path           => $batch_info,
    smoker_home    => $smoker_home,
    suite_root     => $suite_root,
    requested_plan => $plan_path,
    original_plan  => $original_plan,
    executed_plan  => $deduplicated_plan,
    skipped_dup    => $skipped_duplicates,
    input_rows     => $input_rows,
    unique_rows    => $unique_rows,
    duplicate_rows => $duplicate_rows,
    scheduler_args => \@scheduler_args,
);

# -------------------------------------------------------------------
# Startup information
# -------------------------------------------------------------------

print "INFO: SMOKER_HOME=$ENV{SMOKER_HOME}\n";
print "INFO: SMOKER_ROOT=$ENV{SMOKER_ROOT}\n";

print "INFO: SMOKER_LOCAL_MIRROR="
    . (
        defined $ENV{SMOKER_LOCAL_MIRROR}
        ? $ENV{SMOKER_LOCAL_MIRROR}
        : '(live CPAN)'
    )
    . "\n";

print "INFO: SMOKER_TARBALL_CACHE=$ENV{SMOKER_TARBALL_CACHE}\n";
print "INFO: SMOKER_SNAPSHOT_ROOT="
    . (defined $ENV{SMOKER_SNAPSHOT_ROOT}
        ? $ENV{SMOKER_SNAPSHOT_ROOT}
        : "(not set; bksmoker.sh default)")
    . "\n";
print "INFO: SMOKER_SAVE_MINICPAN=$ENV{SMOKER_SAVE_MINICPAN}\n";
print "INFO: SMOKER_DEFAULT_JOBS=$ENV{SMOKER_DEFAULT_JOBS}\n";
print "INFO: SMOKER_RUN_TIMEOUT=$ENV{SMOKER_RUN_TIMEOUT}\n";
print "INFO: SMOKER_BUILD_LOG_MAX_BYTES=$ENV{SMOKER_BUILD_LOG_MAX_BYTES}\n";
print "INFO: requested_plan=$plan_path\n";
print "INFO: original_plan=$original_plan\n";
print "INFO: executed_plan=$executed_plan_path\n";
print "INFO: skipped_dup=$skipped_duplicates\n";
print "INFO: batch_info=$batch_info\n";
print "INFO: plan_rows=$input_rows unique_rows=$unique_rows duplicate_rows=$duplicate_rows\n";
print "INFO: suite_root=$suite_root\n";
print "INFO: run_log=$run_log\n";

# -------------------------------------------------------------------
# CPAN source information
# -------------------------------------------------------------------

if (defined $ENV{SMOKER_LOCAL_MIRROR}) {
    print "[Smoker] Using existing local MiniCPAN mirror: "
        . "$ENV{SMOKER_LOCAL_MIRROR}\n";
}
else {
    print "[Smoker] No valid local MiniCPAN mirror found; using live CPAN\n";
}

print "[Smoker] Using tarball cache: $ENV{SMOKER_TARBALL_CACHE}\n";

# -------------------------------------------------------------------
# Optional pre-run backup hook
# -------------------------------------------------------------------

my $backup = "$smoker_home/bin/bksmoker.sh";
my $backup_cmd = $ENV{SMOKER_TEST_BACKUP_COMMAND} // $backup;
my $backup_prompt_timeout = 10;
if (defined $ENV{SMOKER_TEST_BACKUP_PROMPT_TIMEOUT}) {
    die "ERROR: invalid SMOKER_TEST_BACKUP_PROMPT_TIMEOUT\n"
        unless $ENV{SMOKER_TEST_BACKUP_PROMPT_TIMEOUT} =~ /\A(?:\d+(?:\.\d*)?|\.\d+)\z/
            && $ENV{SMOKER_TEST_BACKUP_PROMPT_TIMEOUT} > 0;
    $backup_prompt_timeout = $ENV{SMOKER_TEST_BACKUP_PROMPT_TIMEOUT};
}

if (-x $backup_cmd) {
    my $run_backup = 0;

    if (-t STDIN) {
        local $| = 1;

        print "\n";
        print "Run pre-test backup? [y/N] ";
        print "(default N after ${backup_prompt_timeout}s): ";

        my $selector = IO::Select->new(\*STDIN);

        if (!$selector->can_read($backup_prompt_timeout)) {
            print "\n";
            print "INFO: no response after ${backup_prompt_timeout}s; "
                . "skipping pre-test backup\n";
        }
        else {
            my $answer = <STDIN>;
            $answer = '' unless defined $answer;
            $answer =~ s/^\s+|\s+$//g;

            if ($answer =~ /\Ay\z/i) {
                $run_backup = 1;
                print "INFO: pre-test backup will run\n";
            }
            elsif ($answer eq '' || $answer =~ /\An\z/i) {
                print "INFO: pre-test backup skipped by user\n";
            }
            else {
                print "WARN: invalid backup choice '$answer'; "
                    . "using default N and skipping pre-test backup\n";
            }
        }
    }
    else {
        print "INFO: standard input is not interactive; "
            . "skipping pre-test backup by default\n";
    }

    if ($run_backup) {
        print "INFO: running pre-test backup\n";

        my $backup_rc = system { $backup_cmd } $backup_cmd;
        if ($backup_rc != 0) {
            my $exit = system_exit_code($backup_rc);
            $abort_reason = "backup failed rc=$exit";
            die "ERROR: backup failed rc=$exit\n";
        }

        print "INFO: backup complete\n";
    }
}
else {
    warn "WARN: backup hook not found or not executable: $backup_cmd\n";
}

# -------------------------------------------------------------------
# Scheduler
# -------------------------------------------------------------------

my $scheduler = "$smoker_home/bin/run_plan_csv.pl";

unless (-f $scheduler) {
    die "ERROR: scheduler not found: $scheduler\n";
}

print "INFO: starting scheduler\n";

my @cmd_parts = (
    'perl',
    $scheduler,
    '--smoker-root', $smoker_home,
    '--plan',        $executed_plan_path,
    '--suite-root',  $suite_root,
    @scheduler_args,
);

my $cmd = join(' ', map { shell_quote($_) } @cmd_parts)
    . " 2>&1 | tee "
    . shell_quote($run_log);

my $rc = run_scheduler_with_tee($cmd, \$scheduler_pid);
$scheduler_pid = undef;

if ($rc != 0) {
    my $exit = system_exit_code($rc);
    $abort_reason = "scheduler failed rc=$exit";
    die "ERROR: scheduler failed rc=$exit\n";
}

print "INFO: scheduler complete\n";

# -------------------------------------------------------------------
# Trait/outcome analysis
# -------------------------------------------------------------------

my $summary = "$suite_root/summary.csv";
my $traits  = "$smoker_home/archive/dev_tools/llm/scripts/dist_traits.tsv";
my $joiner  = "$smoker_home/analysis/bin/join_traits_to_outcomes.pl";
my $outdir  = "$suite_root/analysis/traits";

if (-f $summary && -f $traits && -f $joiner) {
    print "INFO: running trait/outcome analysis\n";

    my @analysis_parts = (
        'perl',
        $joiner,
        '--summary', $summary,
        '--traits',  $traits,
        '--outdir',  $outdir,
    );

    my $analysis_cmd =
        join(' ', map { shell_quote($_) } @analysis_parts);

    my $analysis_rc =
        system('bash', '-o', 'pipefail', '-c', $analysis_cmd);

    if ($analysis_rc != 0) {
        my $exit = system_exit_code($analysis_rc);
        warn "WARN: trait/outcome analysis failed rc=$exit\n";
    }
    else {
        print "INFO: trait/outcome analysis written: $outdir\n";
    }
}
else {
    print "INFO: trait/outcome analysis not configured\n";
    print "INFO: summary missing: $summary\n"
        unless -f $summary;
    print "INFO: traits database not installed: $traits\n"
        unless -f $traits;
    print "INFO: trait joiner not installed: $joiner\n"
        unless -f $joiner;
}

# -------------------------------------------------------------------
# Result classification audit
# -------------------------------------------------------------------

my $classification_auditor = "$smoker_home/bin/audit_result_classification.pl";

if (-x $classification_auditor) {
    print "INFO: auditing result classifications\n";

    my $classification_rc = system(
        $classification_auditor,
        $suite_root,
        $classification_report,
    );

    if ($classification_rc != 0) {
        my $exit = system_exit_code($classification_rc);
        $abort_reason = "result classification audit failed rc=$exit";
        die "ERROR: result classification audit found unsupported classifications rc=$exit; "
            . "report=$classification_report\n";
    }

    print "INFO: result classification audit written: $classification_report\n";
}
else {
    $abort_reason = "classification auditor not found or not executable: $classification_auditor";
    die "ERROR: classification auditor not found or not executable: $classification_auditor\n";
}

# -------------------------------------------------------------------
# Deterministic batch validation
# -------------------------------------------------------------------

my $validator = "$smoker_home/bin/validate_smoker_batch.pl";

if (-r $validator) {
    print "INFO: running deterministic batch validator\n";

    my $validation_rc = system(
        $^X,
        $validator,
        $suite_root,
        $validation_report,
    );

    my $validation_exit = system_exit_code($validation_rc);

    if ($validation_exit == 0) {
        print "INFO: validator exit code: 0\n";
    }
    elsif ($validation_exit == 1) {
        $validation_failed = 1;
        warn "WARN: validator reported evidence issues; "
            . "report=$validation_report\n";
    }
    else {
        $abort_reason = "validator execution failed rc=$validation_exit";
        die "ERROR: validator execution failed rc=$validation_exit; "
            . "report=$validation_report\n";
    }

    print "INFO: validation report written: $validation_report\n";
}
else {
    $abort_reason = "validator not found or not executable: $validator";

    die "ERROR: validator not found or not executable: $validator\n";
}

# -------------------------------------------------------------------
# Human-readable batch review
# -------------------------------------------------------------------

print "INFO: generating batch review\n";

my $review_ok = generate_batch_review(
    utility   => $review_utility,
    batch_dir => $suite_root,
    output    => $batch_review,
);

if (!$review_ok) {
    $abort_reason = 'batch review generation failed';

    die "ERROR: batch review generation failed; "
        . "report=$batch_review\n";
}

$review_written = 1;

print "INFO: batch review written: $batch_review\n";

# -------------------------------------------------------------------
# Compact review archive
# -------------------------------------------------------------------
# Packaging is deliberately non-fatal. Validator evidence issues control the
# final exit code; the optional upload archive does not.

if (-x $archive_utility) {
    print "INFO: creating compact review archive\n";

    my $archive_rc = system(
        $archive_utility,
        $suite_root,
    );

    if ($archive_rc != 0) {
        my $exit = system_exit_code($archive_rc);

        warn "WARN: review archive creation failed rc=$exit; "
            . "utility=$archive_utility\n";
    }
    elsif (-f $review_archive) {
        print "INFO: review archive written: $review_archive\n";
    }
    else {
        warn "WARN: review archive utility returned success, but expected "
            . "archive was not found: $review_archive\n";
    }
}
else {
    warn "WARN: review archive utility not found or not executable: "
        . "$archive_utility\n";
}

# -------------------------------------------------------------------
# Final summary
# -------------------------------------------------------------------

print "INFO: outputs:\n";
print "INFO:   $suite_root\n";
print "INFO:   $original_plan\n";
print "INFO:   $deduplicated_plan\n";
print "INFO:   $skipped_duplicates\n";
print "INFO:   $batch_info\n";
print "INFO:   $validation_report\n";
print "INFO:   $classification_report\n" if -f $classification_report;
print "INFO:   $batch_review\n";
print "INFO:   $review_archive\n" if -f $review_archive;
print "INFO:   $summary\n";
print "INFO:   $run_log\n";
# Trait-analysis outputs are intentionally omitted from the final summary.
# When trait/outcome analysis is skipped, these files may not contain
# meaningful results and should not be advertised as completed outputs.

# -------------------------------------------------------------------
# Docker cleanup
# -------------------------------------------------------------------

my $docker_cleanup = "$smoker_home/bin/docker_cleanup.sh";

if (-x $docker_cleanup) {
    my $cleanup_rc = system($docker_cleanup);

    if ($cleanup_rc != 0) {
        my $exit = system_exit_code($cleanup_rc);
        warn "WARN: docker cleanup failed rc=$exit\n";
    }
}
else {
    warn "WARN: docker cleanup script not found or not executable: "
        . "$docker_cleanup\n";
}

print "INFO: final validator exit code: "
    . ($validation_failed ? 1 : 0)
    . "\n";

$run_completed_normally = 1;

exit($validation_failed ? 1 : 0);

# -------------------------------------------------------------------
# Helpers
# -------------------------------------------------------------------


sub prepare_tarball_cache {
    my (%args) = @_;

    my $requested = $args{requested};
    my $fallback  = $args{fallback};

    for my $path ($requested, $fallback) {
        next unless defined $path && length $path;

        my $ok = eval {
            make_path("$path/authors/id");

            my $probe = "$path/authors/id/.smoker-write-test-$$";
            open my $fh, '>', $probe
                or die "cannot create $probe: $!";
            print {$fh} "write test\n"
                or die "cannot write $probe: $!";
            close $fh
                or die "cannot close $probe: $!";
            unlink $probe
                or die "cannot remove $probe: $!";
            1;
        };

        if ($ok) {
            if ($path ne $requested) {
                warn "WARN: requested tarball cache is not writable; "
                    . "using fallback $path\n";
            }
            $ENV{SMOKER_TARBALL_CACHE} = $path;
            return;
        }

        warn "WARN: tarball cache is not writable: $path: $@";
    }

    die "ERROR: no writable Smoker tarball cache is available\n";
}

sub run_scheduler_with_tee {
    my ($cmd, $pid_ref) = @_;

    my $pid = fork();
    die "ERROR: cannot fork scheduler: $!\n" unless defined $pid;

    if ($pid == 0) {
        setpgrp(0, 0);
        exec 'bash', '-o', 'pipefail', '-c', $cmd;
        exit 255;
    }

    $$pid_ref = $pid;
    waitpid($pid, 0);
    return $?;
}

sub stop_scheduler_group {
    my ($pid, $signal) = @_;
    return unless defined $pid && $pid > 0;

    kill $signal, -$pid;
    my $leader_reaped = 0;
    my $deadline = time() + 5;
    while (time() < $deadline && kill 0, -$pid) {
        if (!$leader_reaped && waitpid($pid, 1) == $pid) {
            $leader_reaped = 1;
        }
        select undef, undef, undef, 0.2;
    }

    if (kill 0, -$pid) {
        kill 'KILL', -$pid;
    }

    waitpid($pid, 0) unless $leader_reaped;
}

sub generate_batch_review {
    my (%args) = @_;

    my $utility   = $args{utility};
    my $batch_dir = $args{batch_dir};
    my $output    = $args{output};
    my $quiet     = $args{quiet} // 0;

    if (!-f $utility) {
        warn "WARN: batch review utility not found: $utility\n"
            unless $quiet;

        return 0;
    }

    my @parts = (
        'perl',
        $utility,
        $batch_dir,
    );

    my $cmd = join(' ', map { shell_quote($_) } @parts)
        . ' > '
        . shell_quote($output)
        . ' 2>&1';

    my $rc = system(
        'bash',
        '-o',
        'pipefail',
        '-c',
        $cmd,
    );

    if ($rc != 0) {
        my $exit = system_exit_code($rc);

        warn "WARN: batch review utility failed rc=$exit; "
            . "output=$output\n"
            unless $quiet;

        return 0;
    }

    return 1;
}

sub append_aborted_notice {
    my (%args) = @_;

    my $output = $args{output};
    my $reason = $args{reason};

    open my $fh, '>>', $output
        or do {
            warn "WARN: cannot append aborted notice to $output: $!\n";
            return;
        };

    print {$fh} "\n", '=' x 78, "\n";
    print {$fh} "TEST ABORTED\n";
    print {$fh} "Reason: $reason\n";
    print {$fh} '=' x 78, "\n";

    close $fh
        or warn "WARN: cannot close batch review $output: $!\n";
}

sub deduplicate_plan {
    my (%args) = @_;

    return deduplicate_csv_preserving_comments(
        source_path     => $args{source_path},
        output_path     => $args{output_path},
        duplicates_path => $args{duplicates_path},
    );
}

sub write_batch_info {
    my (%args) = @_;

    open my $fh, '>', $args{path}
        or die "ERROR: cannot write batch metadata $args{path}: $!\n";

    my $git_commit = command_output(
        'git',
        '-C',
        $args{smoker_home},
        'rev-parse',
        'HEAD',
    );

    my $docker_version = command_output(
        'docker',
        '--version',
    );

    my $perl_version = sprintf('%vd', $^V);
    my $hostname     = command_output('hostname');
    my $kernel       = command_output('uname', '-srmo');
    my $started      = scalar localtime();

    my $scheduler_args = join(
        ' ',
        map { shell_quote($_) } @{ $args{scheduler_args} },
    );

    my @pairs = (
        [format_version          => 1],
        [created_local           => $started],
        [hostname                => $hostname],
        [kernel                  => $kernel],
        [host_perl               => $perl_version],
        [docker_version          => $docker_version],
        [smoker_home             => $args{smoker_home}],
        [smoker_git_commit       => $git_commit],
        [suite_root              => $args{suite_root}],
        [requested_plan_path     => $args{requested_plan}],
        [original_plan           => $args{original_plan}],
        [executed_plan           => $args{executed_plan}],
        [skipped_dup             => $args{skipped_dup}],
        [original_plan_rows      => $args{input_rows}],
        [deduplicated_rows       => $args{unique_rows}],
        [removed_duplicate_rows  => $args{duplicate_rows}],
        [scheduler_arguments     => $scheduler_args],
        [local_mirror            =>
            ($ENV{SMOKER_LOCAL_MIRROR} // 'live CPAN')],
        [tarball_cache           => $ENV{SMOKER_TARBALL_CACHE}],
    );

    for my $pair (@pairs) {
        my ($key, $value) = @{$pair};

        $value = ''
            unless defined $value;

        $value =~ s/[\r\n]+/ /g;

        print {$fh} "$key=$value\n"
            or die "ERROR: cannot write batch metadata "
                . "$args{path}: $!\n";
    }

    close $fh
        or die "ERROR: cannot close batch metadata $args{path}: $!\n";
}

sub command_output {
    my (@cmd) = @_;

    my $quoted =
        join(' ', map { shell_quote($_) } @cmd)
        . ' 2>/dev/null';

    my $output = qx{$quoted};

    return 'unknown'
        if $? != 0;

    $output =~ s/\s+\z//;

    return length($output)
        ? $output
        : 'unknown';
}

sub csv_quote {
    my ($value) = @_;

    $value = ''
        unless defined $value;

    $value =~ s/"/""/g;

    return qq{"$value"};
}

sub timestamp {
    my @t = localtime();

    return sprintf(
        "%04d%02d%02d_%02d%02d%02d",
        $t[5] + 1900,
        $t[4] + 1,
        $t[3],
        $t[2],
        $t[1],
        $t[0],
    );
}

sub shell_quote {
    my ($s) = @_;

    die "ERROR: cannot shell-quote an undefined value\n"
        unless defined $s;

    $s =~ s/'/'"'"'/g;

    return "'$s'";
}

sub system_exit_code {
    my ($status) = @_;

    if ($status == -1) {
        return 255;
    }

    if ($status & 127) {
        return 128 + ($status & 127);
    }

    return $status >> 8;
}
