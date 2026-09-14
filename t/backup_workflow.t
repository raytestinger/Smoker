use strict;
use warnings;

use File::Copy qw(copy);
use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempdir);
use IO::Pty;
use POSIX qw(:sys_wait_h setsid);
use Test::More;
use Time::HiRes qw(time);

sub write_file {
    my ($path, $text, $mode) = @_;
    my ($vol, $dir) = File::Spec->splitpath($path);
    make_path($dir) if length $dir && !-d $dir;
    open my $fh, '>', $path or die "write $path: $!";
    print {$fh} $text;
    close $fh or die "close $path: $!";
    chmod $mode, $path if defined $mode;
}

sub slurp {
    my ($path) = @_;
    open my $fh, '<', $path or return undef;
    local $/;
    return <$fh>;
}

sub make_plan {
    my ($root) = @_;
    my $plan = File::Spec->catfile($root, 'plan.csv');
    write_file(
        $plan,
        "base,mode,module,version,dep_one,dep_one_version,dep_two,dep_two_version\n"
            . "perl:5.38,baseline,Example::Module,1.0,,,,\n",
    );
    return $plan;
}

sub make_launcher_tree {
    my ($root) = @_;
    my $home = File::Spec->catdir($root, 'Smoker Home');
    make_path(File::Spec->catdir($home, 'bin'));
    make_path(File::Spec->catdir($home, 'lib', 'Smoker'));

    copy('Run_Smoker.pl', File::Spec->catfile($home, 'Run_Smoker.pl'))
        or die "copy Run_Smoker.pl: $!";
    copy(File::Spec->catfile('lib', 'Smoker', 'PlanCSV.pm'),
        File::Spec->catfile($home, 'lib', 'Smoker', 'PlanCSV.pm'))
        or die "copy PlanCSV.pm: $!";

    my $backup_log = File::Spec->catfile($root, 'backup.log');
    write_file(
        File::Spec->catfile($home, 'bin', 'bksmoker.sh'),
        "#!/usr/bin/env bash\nset -euo pipefail\necho \"backup:\$SMOKER_HOME\" >> "
            . shell_quote($backup_log) . "\nexit \${FAKE_BACKUP_RC:-0}\n",
        0755,
    );

    write_file(
        File::Spec->catfile($home, 'bin', 'run_plan_csv.pl'),
        <<'SCRIPT',
#!/usr/bin/env perl
use strict;
use warnings;
use Text::CSV;
my %arg;
while (@ARGV) {
    my $k = shift @ARGV;
    $arg{$k} = shift @ARGV if @ARGV;
}
my $suite = $arg{'--suite-root'} or die "missing suite root\n";
my $runs = "$suite/runs";
mkdir $runs unless -d $runs;
my $run = "$runs/000001";
mkdir $run unless -d $run;
open my $rfh, '>', "$run/rc.code" or die $!;
print {$rfh} "0\n";
close $rfh;
open my $mfh, '>', "$run/result.meta" or die $!;
print {$mfh} "run_id=000001\nstatus=PASS\nsubtype=\nrc=0\nrun_dir=$run\nnote=\n";
close $mfh;
open my $efh, '>', "$run/execution_trail.audit" or die $!;
print {$efh} "record=framework_execution_trail\nscope=factual_producer_execution_record\nrun_id=000001\nrun_dir=$run\n";
close $efh;
my @header = qw(run_id batch base mode module version dep_one dep_one_version dep_two dep_two_version status rc start_ts end_ts elapsed_s run_dir note);
my $csv = Text::CSV->new({ binary => 1, eol => "\n" });
open my $sfh, '>', "$suite/summary.csv" or die $!;
$csv->print($sfh, \@header);
$csv->print($sfh, ['000001', 'batch', 'perl:5.38', 'baseline', 'Example::Module', '1.0', '', '', '', '', 'PASS', 0, '2026-01-01T00:00:00Z', '2026-01-01T00:00:01Z', '1.000000', $run, '']);
close $sfh;
if (defined $ENV{SCHEDULER_STDIN_CAPTURE}) {
    my $line = <STDIN>;
    open my $cfh, '>', $ENV{SCHEDULER_STDIN_CAPTURE} or die $!;
    print {$cfh} defined($line) ? $line : '';
    close $cfh;
}
exit 0;
SCRIPT
        0755,
    );

    for my $name (qw(validate_smoker_batch.pl audit_result_classification.pl nonpass_cpanm_logs.pl)) {
        write_file(
            File::Spec->catfile($home, 'bin', $name),
            "#!/usr/bin/env perl\nuse strict; use warnings;\nmy \$out = \$ARGV[-1];\nif (defined \$out) { open my \$fh, '>', \$out or die \$!; print {\$fh} \"Assessment: PASS\\n\"; close \$fh; }\nprint \"REPORT COMPLETE\\n\";\nexit 0;\n",
            0755,
        );
    }
    write_file(
        File::Spec->catfile($home, 'bin', 'make_review_archive.sh'),
        "#!/usr/bin/env bash\nexit 0\n",
        0755,
    );

    return ($home, $backup_log);
}

sub shell_quote {
    my ($s) = @_;
    $s =~ s/'/'"'"'/g;
    return "'$s'";
}

sub run_launcher_pty {
    my (%args) = @_;
    my $root = tempdir(CLEANUP => 1);
    my ($home, $backup_log) = make_launcher_tree($root);
    my $plan = make_plan($root);
    my $stdin_capture = File::Spec->catfile($root, 'scheduler-stdin.txt');

    my $pty = IO::Pty->new;
    my $pid = fork();
    die "fork: $!" unless defined $pid;
    if ($pid == 0) {
        my $slave = $pty->slave;
        close $pty;
        open STDIN,  '<&', $slave or die $!;
        open STDOUT, '>&', $slave or die $!;
        open STDERR, '>&', $slave or die $!;
        close $slave;
        $ENV{SMOKER_TEST_BACKUP_PROMPT_TIMEOUT} = $args{timeout} // 1;
        $ENV{SCHEDULER_STDIN_CAPTURE} = $stdin_capture
            if $args{capture_stdin};
        $ENV{FAKE_BACKUP_RC} = $args{backup_rc} if defined $args{backup_rc};
        exec $^X, File::Spec->catfile($home, 'Run_Smoker.pl'), $plan;
        die "exec failed: $!";
    }

    close $pty->slave;
    my $output = '';
    my $sent = 0;
    my $deadline = time + ($args{max_seconds} // 5);
    while (time < $deadline) {
        my $rin = '';
        vec($rin, fileno($pty), 1) = 1;
        my $n = select(my $rout = $rin, undef, undef, 0.05);
        if ($n && vec($rout, fileno($pty), 1)) {
            my $buf = '';
            my $read = sysread($pty, $buf, 4096);
            last unless defined $read && $read > 0;
            $output .= $buf;
        }
        if (!$sent && defined $args{input} && $output =~ /Run pre-test backup\? \[y\/N\]/) {
            syswrite($pty, $args{input});
            $sent = 1;
        }
        my $done = waitpid($pid, WNOHANG);
        last if $done == $pid;
    }
    my $done = waitpid($pid, WNOHANG);
    if ($done == 0) {
        kill 'TERM', $pid;
        waitpid($pid, 0);
    }
    elsif ($done < 0) {
        $done = $pid;
    }
    else {
        while (1) {
            my $buf = '';
            my $read = sysread($pty, $buf, 4096);
            last unless defined $read && $read > 0;
            $output .= $buf;
        }
    }
    my $status = $?;
    close $pty;

    return {
        rc => ($status >> 8),
        output => $output,
        backup_log => slurp($backup_log) // '',
        scheduler_stdin => slurp($stdin_capture) // '',
    };
}

sub run_launcher_pipe {
    my (%args) = @_;
    my $root = tempdir(CLEANUP => 1);
    my ($home, $backup_log) = make_launcher_tree($root);
    my $plan = make_plan($root);
    my $out = File::Spec->catfile($root, 'launcher.out');
    my $cmd = join ' ',
        'FAKE_BACKUP_RC=' . shell_quote($args{backup_rc} // 0),
        shell_quote($^X),
        shell_quote(File::Spec->catfile($home, 'Run_Smoker.pl')),
        shell_quote($plan),
        '>', shell_quote($out),
        '2>&1',
        '<', File::Spec->devnull;
    my $raw = system('bash', '-c', $cmd);
    return {
        rc => ($raw >> 8),
        output => slurp($out) // '',
        backup_log => slurp($backup_log) // '',
    };
}

{
    my $source = slurp('Run_Smoker.pl') // '';
    unlike($source, qr/while \(kill 0, -\$pid\)/,
        'launcher shutdown does not contain an unbounded process-group wait');
    like($source, qr/kill ['"]KILL['"], -\$pid/,
        'launcher shutdown escalates to KILL after its grace period');
}

{
    local @ARGV = ();
    local %ENV = %ENV;
    local @INC = (File::Spec->rel2abs('lib'), @INC);
    my $loaded;
    {
        no warnings 'redefine';
        $loaded = do File::Spec->rel2abs('Run_Smoker.pl');
    }
    my $load_error = $@ || $!;
    ok(!$loaded && defined &main::stop_scheduler_group,
        'launcher shutdown helper loads without starting a run');
    note("Run_Smoker.pl load stopped as expected: $load_error") if $load_error;

    my $pid = fork();
    die "fork: $!" unless defined $pid;
    if ($pid == 0) {
        setpgrp(0, 0);
        local $SIG{TERM} = 'IGNORE';
        local $SIG{INT} = 'IGNORE';
        select undef, undef, undef, 30;
        exit 0;
    }

    select undef, undef, undef, 0.1;
    my $started = time();
    my $error = '';
    eval {
        local $SIG{ALRM} = sub { die "bounded shutdown test alarm\n" };
        alarm 8;
        main::stop_scheduler_group($pid, 'TERM');
        alarm 0;
        1;
    } or do {
        $error = $@ || 'unknown shutdown error';
    };
    my $elapsed = time() - $started;

    is($error, '', 'launcher shutdown completes within the test bound');
    cmp_ok($elapsed, '<', 7,
        'launcher shutdown escalates after a bounded grace period');
    ok(!kill(0, $pid), 'launcher shutdown reliably reaps the group leader');
}

my @prompt_cases = (
    [ "y\n",     1, 'y runs backup' ],
    [ "Y\n",     1, 'Y runs backup' ],
    [ "n\n",     0, 'n skips backup' ],
    [ "N\n",     0, 'N skips backup' ],
    [ "\n",      0, 'Enter skips backup' ],
    [ "  y  \n", 1, 'whitespace around y is handled' ],
    [ "  n  \n", 0, 'whitespace around n is handled' ],
    [ "bogus\n", 0, 'invalid input uses the no-backup default' ],
);

for my $case (@prompt_cases) {
    my ($input, $expected_backup, $label) = @$case;
    my $res = run_launcher_pty(input => $input);
    is($res->{rc}, 0, "$label: launcher exits zero");
    is(($res->{backup_log} =~ tr/\n/\n/), $expected_backup, "$label: backup invocation count");
    is(() = $res->{output} =~ /Run pre-test backup\? \[y\/N\]/g, 1, "$label: prompt appears once");
}

{
    my $res = run_launcher_pty(timeout => 1, max_seconds => 4);
    is($res->{rc}, 0, 'timeout defaults to skipping backup');
    is(($res->{backup_log} =~ tr/\n/\n/), 0, 'timeout does not invoke backup');
}

{
    my $res = run_launcher_pty(input => "y\nNEXT\n", capture_stdin => 1);
    is($res->{scheduler_stdin}, "NEXT\n", 'subsequent input remains available');
}

{
    my $res = run_launcher_pipe();
    is($res->{rc}, 0, 'noninteractive invocation does not hang');
    is(($res->{backup_log} =~ tr/\n/\n/), 0, 'noninteractive invocation skips default backup');
}

{
    my $res = run_launcher_pty(input => "y\n", backup_rc => 7);
    isnt($res->{rc}, 0, 'failed backup prevents continuation');
    like($res->{output}, qr/backup failed/i, 'failure message identifies backup failure');
}

sub make_fake_command_dir {
    my ($root, %args) = @_;
    my $bin = File::Spec->catdir($root, 'fakebin');
    make_path($bin);
    write_file(File::Spec->catfile($bin, 'mountpoint'), "#!/bin/bash\nexit ${\($args{mountpoint_rc} // 0)}\n", 0755);
    write_file(File::Spec->catfile($bin, 'date'), "#!/bin/bash\necho \"${\($args{timestamp} // '2026-01-01_000001')}\"\n", 0755);
    write_file(
        File::Spec->catfile($bin, 'mv'),
        <<'SCRIPT',
#!/bin/bash
set -euo pipefail
if [[ "${1:-}" == "--" ]]; then shift; fi
src="$1"
dest="$2"
/bin/cp -R -- "$src" "$dest"
/bin/rm -rf -- "$src"
SCRIPT
        0755,
    );
    write_file(
        File::Spec->catfile($bin, 'mkdir'),
        <<'SCRIPT',
#!/bin/bash
exec /bin/mkdir "$@"
SCRIPT
        0755,
    );
    write_file(
        File::Spec->catfile($bin, 'rm'),
        <<'SCRIPT',
#!/bin/bash
exec /bin/rm "$@"
SCRIPT
        0755,
    );
    write_file(
        File::Spec->catfile($bin, 'tar'),
        <<'SCRIPT',
#!/bin/bash
set -euo pipefail
echo "$@" >> "$FAKE_TAR_LOG"
if [[ "${FAKE_TAR_RC:-0}" != 0 ]]; then exit "$FAKE_TAR_RC"; fi
out=
prev=
for arg in "$@"; do
    if [[ "$prev" == "-czf" ]]; then out="$arg"; break; fi
    prev="$arg"
done
[[ -n "$out" ]] || exit 22
printf 'fake archive\n' > "$out"
SCRIPT
        0755,
    );
    if ($args{rsync_available}) {
        write_file(
            File::Spec->catfile($bin, 'rsync'),
            <<'SCRIPT',
#!/bin/bash
set -euo pipefail
echo "$@" >> "$FAKE_RSYNC_LOG"
dest="${@: -1}"
/bin/mkdir -p "$dest"
SCRIPT
            0755,
        );
    }
    return $bin;
}

sub run_backup_script {
    my (%args) = @_;
    my $root = tempdir(CLEANUP => 1);
    my $src = $args{missing_source}
        ? File::Spec->catdir($root, 'missing source')
        : File::Spec->catdir($root, 'source tree');
    my $dest = File::Spec->catdir($root, 'backup dest');
    make_path($src) unless $args{missing_source};
    make_path($dest) unless $args{missing_dest};
    if (!$args{missing_source}) {
        write_file(File::Spec->catfile($src, 'file.txt'), "content\n");
        make_path(File::Spec->catdir($src, 'minicpan', 'modules'));
    }

    my $timestamp = $args{timestamp} // '2026-01-01_000001';
    if ($args{preexisting_archive}) {
        write_file(File::Spec->catfile($dest, "Smoker_${timestamp}.tar.gz"), "old\n");
    }
    my $fakebin = make_fake_command_dir(
        $root,
        timestamp       => $timestamp,
        mountpoint_rc   => ($args{mountpoint_rc} // 0),
        rsync_available => ($args{rsync_available} // 1),
    );
    my $tar_log = File::Spec->catfile($root, 'tar.log');
    my $rsync_log = File::Spec->catfile($root, 'rsync.log');
    my $out = File::Spec->catfile($root, 'backup.out');
    my $cmd = join ' ',
        'PATH=' . shell_quote($fakebin),
        'SMOKER_HOME=' . shell_quote($src),
        'SMOKER_SNAPSHOT_ROOT=' . shell_quote($dest),
        'SMOKER_BACKUP_TIMESTAMP=' . shell_quote($timestamp),
        'SMOKER_BACKUP_MINICPAN=' . shell_quote($args{minicpan} // 0),
        'FAKE_TAR_LOG=' . shell_quote($tar_log),
        'FAKE_RSYNC_LOG=' . shell_quote($rsync_log),
        'FAKE_TAR_RC=' . shell_quote($args{tar_rc} // 0),
        shell_quote('/bin/bash'), shell_quote('bin/bksmoker.sh'),
        '>', shell_quote($out),
        '2>&1';
    my $raw = system('bash', '-c', $cmd);
    return {
        rc => ($raw >> 8),
        output => slurp($out) // '',
        tar_log => slurp($tar_log) // '',
        rsync_log => slurp($rsync_log) // '',
        archive => File::Spec->catfile($dest, "Smoker_${timestamp}.tar.gz"),
        root => $root,
    };
}

{
    my $res = run_backup_script(rsync_available => 0);
    is($res->{rc}, 0, 'normal source backup succeeds when rsync is unavailable');
    unlike($res->{output}, qr/Run pre-test backup\?/, 'direct bksmoker.sh does not duplicate prompt');
    ok(-f $res->{archive}, 'success is reported after archive exists');
    like($res->{tar_log}, qr/--exclude=\.\/test_results/, 'intended exclusions are passed to tar');
    like($res->{tar_log}, qr/\Qsource tree\E/, 'paths containing spaces are passed safely');
    is($res->{rsync_log}, '', 'MiniCPAN is not included by default');
}

{
    my $res = run_backup_script(minicpan => 1, rsync_available => 0);
    isnt($res->{rc}, 0, 'explicit MiniCPAN backup fails when rsync is unavailable');
    like($res->{output}, qr/rsync is not installed/i, 'missing rsync failure is clear');
}

{
    my $res = run_backup_script(minicpan => 1, rsync_available => 1);
    is($res->{rc}, 0, 'explicit MiniCPAN backup succeeds');
    ok(-f $res->{archive}, 'source archive still exists when MiniCPAN backup runs');
    like($res->{rsync_log}, qr/minicpan/, 'MiniCPAN is included only by explicit policy');
}

for my $case (
    [ 'missing source is rejected', { missing_source => 1 }, qr/source directory/i ],
    [ 'missing/unusable destination is rejected', { missing_dest => 1 }, qr/destination|snapshot/i ],
    [ 'unmounted destination is rejected', { mountpoint_rc => 1 }, qr/mounted filesystem/i ],
    [ 'pre-existing output archive is not silently overwritten', { preexisting_archive => 1 }, qr/already exists/i ],
    [ 'archive-command failure is propagated', { tar_rc => 9 }, qr/tar|archive/i ],
) {
    my ($label, $args, $re) = @$case;
    my $res = run_backup_script(%$args);
    isnt($res->{rc}, 0, $label);
    like($res->{output}, $re, "$label: clear error");
}

done_testing;
