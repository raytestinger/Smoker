use strict;
use warnings;

use File::Path qw(make_path remove_tree);
use File::Spec;
use File::Temp qw(tempdir);
use Test::More;
use Text::CSV;

use lib 'lib';
use lib 't/lib';
use Smoker::Result qw(finalize_result);
use Smoker::TestBatch qw(make_batch read_text);

sub write_text {
    my ($path, $text) = @_;
    open my $fh, '>', $path or die "write $path: $!";
    print {$fh} $text;
    close $fh or die "close $path: $!";
}

sub append_text {
    my ($path, $text) = @_;
    open my $fh, '>>', $path or die "append $path: $!";
    print {$fh} $text;
    close $fh or die "close $path: $!";
}

sub slurp {
    my ($path) = @_;
    return undef unless -f $path;
    open my $fh, '<', $path or die "read $path: $!";
    local $/;
    my $text = <$fh>;
    close $fh;
    return $text;
}

sub csv_rows {
    my ($path) = @_;
    my $csv = Text::CSV->new({ binary => 1, auto_diag => 1 });
    open my $fh, '<', $path or die "read $path: $!";
    my $header = $csv->getline($fh);
    $csv->column_names(@$header);
    my @rows;
    while (my $row = $csv->getline_hr($fh)) {
        push @rows, $row;
    }
    close $fh;
    return ($header, \@rows);
}

sub write_summary {
    my ($path, $header, $rows) = @_;
    my $csv = Text::CSV->new({ binary => 1, eol => "\n" });
    open my $fh, '>', $path or die "write $path: $!";
    $csv->print($fh, $header);
    $csv->print($fh, [ @{$_}{@$header} ]) for @$rows;
    close $fh or die "close $path: $!";
}

sub make_clean_fixture {
    my (%args) = @_;
    my $root = tempdir(CLEANUP => 1);
    my ($batch, $run) = make_batch(
        $root,
        rc       => $args{rc} // 125,
        status   => $args{status} // 'FAIL',
        subtype  => $args{subtype} // 'framework_error',
        note     => $args{note} // 'Framework recovery at test: worker exception',
        evidence_file => $args{evidence_file} // 'framework_error.evidence',
        evidence_file_text => $args{evidence_file_text}
            // "framework worker exception raw_wait_status=2304 signal=0 core_dumped=0\n",
    );
    append_text(
        File::Spec->catfile($run, 'result.meta'),
        join("\n",
            "raw_return_code=9",
            "raw_wait_status=2304",
            "interrupted=0",
            "interrupt_signal=",
        ) . "\n",
    );
    write_text(
        File::Spec->catfile($run, 'framework_error.evidence'),
        join("\n",
            "framework_error=1",
            "reason=worker exception",
            "stage=reap",
            "worker_pid=4242",
            "raw_return_code=9",
            "raw_wait_status=2304",
            "interrupted=0",
            "interrupt_signal=",
            "core_dumped=0",
            "run_id=000001",
        ) . "\n",
    );
    write_text(File::Spec->catfile($batch, 'FAULT_TEST_BATCH'), "phase6 disposable fixture\n");
    return ($root, $batch, $run);
}

sub state_snapshot {
    my ($batch, $run) = @_;
    my $runs = File::Spec->catdir($batch, 'runs');
    my @run_entries;
    if (-d $runs) {
        opendir my $dh, $runs or die "opendir $runs: $!";
        @run_entries = sort grep { $_ ne '.' && $_ ne '..' } readdir $dh;
        closedir $dh;
    }
    return join "\n",
        "runs=" . join(',', @run_entries),
        map { slurp($_) // '<missing>' }
            File::Spec->catfile($run, 'rc.code'),
            File::Spec->catfile($run, 'result.meta'),
            File::Spec->catfile($batch, 'summary.csv'),
            File::Spec->catfile($run, 'execution_trail.audit'),
            File::Spec->catfile($run, 'framework_error.evidence');
}

sub validate_batch {
    my ($batch) = @_;
    die "missing FAULT_TEST_BATCH safety marker in $batch\n"
        unless -f File::Spec->catfile($batch, 'FAULT_TEST_BATCH');
    my $report = File::Spec->catfile(dirname_of($batch), 'validation-' . int(rand(1_000_000)) . '.txt');
    my $raw = system($^X, 'bin/validate_smoker_batch.pl', $batch, $report);
    return ($raw >> 8, slurp($report) // '');
}

sub dirname_of {
    my ($path) = @_;
    my @parts = File::Spec->splitdir($path);
    pop @parts;
    return File::Spec->catdir(@parts);
}

sub mutate_meta {
    my ($run, $code) = @_;
    my $path = File::Spec->catfile($run, 'result.meta');
    my $text = slurp($path) // '';
    $code->(\$text);
    write_text($path, $text);
}

sub mutate_summary {
    my ($batch, $code) = @_;
    my $path = File::Spec->catfile($batch, 'summary.csv');
    my ($header, $rows) = csv_rows($path);
    $code->($header, $rows);
    write_summary($path, $header, $rows);
}

sub assert_clean_control {
    my ($label) = @_;
    my ($root, $batch) = make_clean_fixture();
    my ($rc, $report) = validate_batch($batch);
    is($rc, 0, "$label clean control returns zero");
    like($report, qr/Assessment: PASS/, "$label clean control passes");
}

{
    my $root = tempdir(CLEANUP => 1);
    my $run = File::Spec->catdir($root, 'runs', '000001');
    make_path($run);
    finalize_result(
        run_id => '000001',
        batch => 'producer_trail',
        base => 'perl:5.38',
        mode => 'baseline',
        module => 'Trail::Producer',
        version => '1.0',
        dep_one => '',
        dep_one_version => '',
        dep_two => '',
        dep_two_version => '',
        status => 'FAIL',
        subtype => 'framework_error',
        rc => 125,
        start_ts => '2026-01-01T00:00:00Z',
        end_ts => '2026-01-01T00:00:01Z',
        elapsed_s => '1.000000',
        run_dir => $run,
        summary_file => File::Spec->catfile($root, 'summary.csv'),
        note => 'Framework recovery at test: worker exception',
        framework_reason => 'worker exception',
        stage => 'test',
        raw_return_code => 9,
        raw_wait_status => 2304,
        interrupted => 0,
        interrupt_signal => '',
        core_dumped => 0,
    );
    my $trail = slurp(File::Spec->catfile($run, 'execution_trail.audit')) // '';
    unlike($trail, qr/^(?:assessment|artifact_completeness)=PASS$/m,
        'producer execution trail does not self-certify PASS or completeness');
}

{
    my ($root, $batch) = make_clean_fixture();
    my ($rc1) = validate_batch($batch);
    write_text(
        File::Spec->catfile($batch, 'result_classification_audit.txt'),
        "Classification evidence: FAIL\nClassified: 0\nUnclassified: 1\n",
    );
    my ($rc2) = validate_batch($batch);
    is($rc1, 0, 'clean fixture passes with producer classification PASS claim');
    is($rc2, 0, 'clean fixture also passes with irrelevant producer classification FAIL claim');
}

my @faults = (
    [ 'P6_MISSING_RC', sub { my ($b, $r) = @_; unlink File::Spec->catfile($r, 'rc.code') }, qr/rc\.code|counts|file/i ],
    [ 'P6_EMPTY_RC', sub { my ($b, $r) = @_; write_text(File::Spec->catfile($r, 'rc.code'), '') }, qr/rc\.code|quality/i ],
    [ 'P6_MALFORMED_RC', sub { my ($b, $r) = @_; write_text(File::Spec->catfile($r, 'rc.code'), "bad\n") }, qr/rc\.code|integer/i ],
    [ 'P6_MISSING_META', sub { my ($b, $r) = @_; unlink File::Spec->catfile($r, 'result.meta') }, qr/result\.meta|counts/i ],
    [ 'P6_MALFORMED_META', sub { my ($b, $r) = @_; write_text(File::Spec->catfile($r, 'result.meta'), "not meta\n") }, qr/result\.meta|missing/i ],
    [ 'P6_MISSING_SUMMARY_ROW', sub { my ($b) = @_; my ($h) = csv_rows(File::Spec->catfile($b, 'summary.csv')); write_summary(File::Spec->catfile($b, 'summary.csv'), $h, []) }, qr/counts|summary/i ],
    [ 'P6_DUP_SUMMARY_ROW', sub { my ($b) = @_; mutate_summary($b, sub { my ($h, $r) = @_; push @$r, { %{ $r->[0] } } }) }, qr/duplicate|summary/i ],
    [ 'P6_WRONG_SUMMARY_STATUS', sub { my ($b) = @_; mutate_summary($b, sub { $_[1][0]{status} = 'PASS' }) }, qr/status|consistency/i ],
    [ 'P6_WRONG_SUMMARY_RC', sub { my ($b) = @_; mutate_summary($b, sub { $_[1][0]{rc} = '0' }) }, qr/rc|mismatch/i ],
    [ 'P6_PASS_WITH_125', sub { my ($b, $r) = @_; mutate_summary($b, sub { $_[1][0]{status} = 'PASS' }); mutate_meta($r, sub { ${$_[0]} =~ s/status=FAIL/status=PASS/ }) }, qr/status|rc/i ],
    [ 'P6_FRAMEWORK_WITH_RC0', sub { my ($b, $r) = @_; write_text(File::Spec->catfile($r, 'rc.code'), "0\n"); mutate_summary($b, sub { $_[1][0]{rc} = '0'; $_[1][0]{status} = 'PASS' }); mutate_meta($r, sub { ${$_[0]} =~ s/rc=125/rc=0/; ${$_[0]} =~ s/status=FAIL/status=PASS/ }) }, qr/framework_error|rc=125|subtype/i ],
    [ 'P6_BARE_FAIL_125', sub { my ($b, $r) = @_; mutate_meta($r, sub { ${$_[0]} =~ s/subtype=framework_error/subtype=/ }) }, qr/rc=125|framework/i ],
    [ 'P6_FRAMEWORK_NO_REASON', sub { my ($b, $r) = @_; mutate_meta($r, sub { ${$_[0]} =~ s/note=.*$/note=/m }); mutate_summary($b, sub { $_[1][0]{note} = '' }); my $p = File::Spec->catfile($r, 'framework_error.evidence'); my $t = slurp($p); $t =~ s/reason=.*$/reason=/m; write_text($p, $t) }, qr/reason|note|framework/i ],
    [ 'P6_MISSING_FRAMEWORK_EVIDENCE', sub { my ($b, $r) = @_; unlink File::Spec->catfile($r, 'framework_error.evidence') }, qr/framework-error evidence|special FAIL/i ],
    [ 'P6_CORRUPT_FRAMEWORK_EVIDENCE', sub { my ($b, $r) = @_; write_text(File::Spec->catfile($r, 'framework_error.evidence'), "ordinary text\n") }, qr/framework-error evidence|special FAIL/i ],
    [ 'P6_RAW_WAIT_MISMATCH', sub { my ($b, $r) = @_; mutate_meta($r, sub { ${$_[0]} =~ s/raw_wait_status=.*/raw_wait_status=9999/ }) }, qr/raw wait|wait status|framework/i ],
    [ 'P6_SIGNAL_MISMATCH', sub { my ($b, $r) = @_; mutate_meta($r, sub { ${$_[0]} =~ s/interrupt_signal=.*/interrupt_signal=9/; ${$_[0]} =~ s/interrupted=0/interrupted=1/ }) }, qr/signal|framework/i ],
    [ 'P6_CORE_MISMATCH', sub { my ($b, $r) = @_; append_text(File::Spec->catfile($r, 'framework_error.evidence'), "core_dumped=1\nraw_wait_status=0\n") }, qr/core|wait|framework/i ],
    [ 'P6_FORK_CLAIMED_PID', sub { my ($b, $r) = @_; write_text(File::Spec->catfile($r, 'framework_error.evidence'), "framework_error=1\nreason=fork failed\nstage=fork\nworker_pid=1234\nwait_status_unavailable=no wait status existed\n") }, qr/fork|worker PID|framework/i ],
    [ 'P6_FORK_MISSING_STAGE', sub { my ($b, $r) = @_; write_text(File::Spec->catfile($r, 'framework_error.evidence'), "framework_error=1\nreason=fork failed\nworker_pid_unavailable=no worker PID existed\nwait_status_unavailable=no wait status existed\n") }, qr/stage|fork|framework/i ],
    [ 'P6_ORPHAN_RUN_DIR', sub { my ($b) = @_; my $orphan = File::Spec->catdir($b, 'runs', '999999'); make_path($orphan); write_text(File::Spec->catfile($orphan, 'rc.code'), "0\n") }, qr/counts|summary|run directories/i ],
    [ 'P6_SUMMARY_WRONG_RUN_DIR', sub { my ($b) = @_; mutate_summary($b, sub { $_[1][0]{run_dir} = File::Spec->catdir($b, 'runs', '999999') }) }, qr/run director|summary/i ],
    [ 'P6_MISSING_EXECUTION_TRAIL', sub { my ($b, $r) = @_; unlink File::Spec->catfile($r, 'execution_trail.audit') }, qr/execution_trail|counts/i ],
    [ 'P6_CONTRADICTORY_EXECUTION_TRAIL', sub { my ($b, $r) = @_; write_text(File::Spec->catfile($r, 'execution_trail.audit'), "event=execution_trail\nrun_id=999999\nrc=0\nstatus=PASS\n") }, qr/execution_trail|contradict/i ],
    [ 'P6_FALSE_INTEGRITY_PASS', sub { my ($b, $r) = @_; append_text(File::Spec->catfile($r, 'execution_trail.audit'), "integrity=PASS\nverified=PASS\n"); unlink File::Spec->catfile($r, 'rc.code') }, qr/rc\.code|counts/i ],
    [ 'P6_FALSE_COMPLETENESS_CLAIM', sub { my ($b, $r) = @_; append_text(File::Spec->catfile($r, 'execution_trail.audit'), "complete=1\nartifact_completeness=PASS\n"); unlink File::Spec->catfile($r, 'rc.code') }, qr/rc\.code|counts/i ],
    [ 'P6_FALSE_CLASSIFICATION_CLAIM', sub { my ($b, $r) = @_; write_text(File::Spec->catfile($b, 'result_classification_audit.txt'), "Classification evidence: PASS\nClassified: 1\nUnclassified: 0\n"); mutate_meta($r, sub { ${$_[0]} =~ s/subtype=framework_error/subtype=/ }) }, qr/rc=125|framework/i ],
);

for my $fault (@faults) {
    my ($id, $mutate, $evidence_re) = @$fault;
    my ($root, $batch, $run) = make_clean_fixture();
    my $before = state_snapshot($batch, $run);

    $mutate->($batch, $run);

    my $after = state_snapshot($batch, $run);

    isnt($after, $before, "$id injection changed the fixture");
    my ($rc, $report) = validate_batch($batch);
    isnt($rc, 0, "$id validator returns nonzero");
    like($report, $evidence_re, "$id validation evidence identifies the fault");
}

{
    my ($root, $batch, $run) = make_clean_fixture();
    append_text(File::Spec->catfile($run, 'execution_trail.audit'), "producer_claim=FAIL\n");
    my ($rc, $report) = validate_batch($batch);
    is($rc, 0, 'P6_IRRELEVANT_PRODUCER_FAIL clean artifacts still pass');
    like($report, qr/Assessment: PASS/, 'P6_IRRELEVANT_PRODUCER_FAIL reports PASS');
}

assert_clean_control('phase6 final');

done_testing;
