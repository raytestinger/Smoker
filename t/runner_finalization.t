use strict;
use warnings;

use File::Spec;
use File::Basename qw(basename);
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use Test::More;
use Text::CSV;

use lib 'lib';
use Smoker::Runner ();
use Smoker::Result qw(finalize_result);

{
    package FinalizationTestRunner;
    use parent 'Smoker::Runner';
    use File::Path qw(make_path);
    use File::Spec;

    sub set_attempts { $_[0]{test_attempts} = $_[1] }
    sub set_fault    { $_[0]{test_fault} = $_[1] }

    sub _run_docker_attempt {
        my ($self, %args) = @_;
        my $fault = $self->{test_fault} || '';

        open my $cmd, '>', $args{cmd_file} or die $!;
        print {$cmd} "fake docker command\n";
        close $cmd or die $!;

        open my $out, '>', $args{run_out} or die $!;
        print {$out} "fake execution\n";
        close $out or die $!;

        die "injected exception before rc.code\n"
            if $fault eq 'before_rc';

        my $attempt = shift @{ $self->{test_attempts} };
        die 'missing fake attempt' unless $attempt;

        if ($fault eq 'summary_append') {
            my $summary = File::Spec->catfile($self->{outdir}, 'summary.csv');
            unlink $summary;
            make_path($summary);
        }
        elsif ($fault eq 'framework_evidence') {
            make_path(File::Spec->catfile($args{run_dir}, 'framework_error.evidence'));
        }

        return { %$attempt };
    }

    sub _write_result_meta {
        my ($self, %args) = @_;
        die "injected result.meta finalization exception\n"
            if ($self->{test_fault} || '') eq 'meta_open'
            && !$args{framework_recovery};
        return $self->SUPER::_write_result_meta(%args);
    }

    sub _write_rc_file {
        my ($self, $path, $rc, $framework_recovery) = @_;
        die "injected rc.code finalization exception\n"
            if ($self->{test_fault} || '') eq 'rc_write'
            && !$framework_recovery;
        return $self->SUPER::_write_rc_file($path, $rc, $framework_recovery);
    }

    sub _write_execution_trail_audit {
        my ($self, %args) = @_;
        die "injected audit finalization exception\n"
            if ($self->{test_fault} || '') eq 'audit_after_meta';
        return $self->SUPER::_write_execution_trail_audit(%args);
    }
}

sub summary_rows {
    my ($outdir) = @_;

    my $path = File::Spec->catfile($outdir, 'summary.csv');
    my $csv = Text::CSV->new({ binary => 1, auto_diag => 1 });
    open my $fh, '<', $path or die "read $path: $!";
    my $header = $csv->getline($fh);
    return [] unless $header;
    $csv->column_names(@$header);

    my @rows;
    while (my $row = $csv->getline_hr($fh)) {
        push @rows, $row;
    }
    close $fh;
    return \@rows;
}

sub read_meta {
    my ($run_dir) = @_;

    my %meta;
    open my $fh, '<', File::Spec->catfile($run_dir, 'result.meta')
        or die "read result.meta: $!";
    while (my $line = <$fh>) {
        chomp $line;
        next unless $line =~ /\A([^=]+)=(.*)\z/;
        $meta{$1} = $2;
    }
    close $fh;
    return \%meta;
}

sub read_text {
    my ($path) = @_;
    return undef unless -f $path;
    open my $fh, '<', $path or die "read $path: $!";
    local $/;
    my $text = <$fh>;
    close $fh;
    return $text;
}

sub run_case {
    my ($name, $attempts, %opts) = @_;

    my $outdir = tempdir(CLEANUP => 1);
    my $runner = FinalizationTestRunner->new(
        smoker_root => '.',
        batch       => $name,
        outdir      => $outdir,
    );
    $runner->set_attempts([ map { +{%$_} } @$attempts ]);
    $runner->set_fault($opts{fault}) if $opts{fault};

    my $rc;
    my $error;
    {
        no warnings 'redefine';
        local *Smoker::Runner::classify_result = sub {
            die "injected classification exception\n"
                if $opts{classify_dies};
            return Smoker::Result::classify_result(@_);
        };

        eval {
            $rc = $runner->run_one(
                run_id  => 1,
                module  => 'Example::Module',
                version => '1.0',
            );
            1;
        } or do {
            $error = $@ || 'unknown exception';
        };
    }

    my $run_dir = File::Spec->catdir($outdir, 'runs', '000001');
    my $rows = -f File::Spec->catfile($outdir, 'summary.csv')
        ? summary_rows($outdir)
        : [];
    my $meta = -f File::Spec->catfile($run_dir, 'result.meta')
        ? read_meta($run_dir)
        : {};

    return {
        outdir  => $outdir,
        run_dir => $run_dir,
        rc      => $rc,
        error   => $error,
        rows    => $rows,
        meta    => $meta,
    };
}

sub assert_single_summary {
    my ($case, $label) = @_;
    is(scalar(@{ $case->{rows} }), 1, "$label: exactly one summary row exists");
}

sub assert_framework_failure {
    my ($case, $label) = @_;

    ok(!$case->{error}, "$label: exception is caught within Runner");
    is($case->{rc}, 125, "$label: caller receives rc=125");
    assert_single_summary($case, $label);

    my $row = $case->{rows}[0] || {};
    is($row->{status}, 'FAIL', "$label: summary status is FAIL");
    is($row->{rc}, '125', "$label: summary rc is 125");
    is($case->{meta}{status}, 'FAIL', "$label: result.meta status is FAIL");
    is($case->{meta}{rc}, '125', "$label: result.meta rc is 125");
    is($case->{meta}{subtype}, 'framework_error', "$label: subtype is framework_error");
    like($case->{meta}{note} // '', qr/\S/, "$label: framework reason is nonempty");

    is((read_text(File::Spec->catfile($case->{run_dir}, 'rc.code')) // ''),
        "125\n", "$label: rc.code is written");
    ok(-s File::Spec->catfile($case->{run_dir}, 'execution_trail.audit'),
        "$label: execution-trail audit is present");

    my $evidence =
        (-f File::Spec->catfile($case->{run_dir}, 'framework_error.evidence') ? 1 : 0)
        ||
        (-f File::Spec->catfile($case->{run_dir}, 'framework_error.note') ? 1 : 0);
    ok($evidence, "$label: framework evidence is present");
}

{
    my $case = run_case(pass => [{ rc => 0 }]);
    ok(!$case->{error}, 'normal PASS does not throw');
    is($case->{rc}, 0, 'normal PASS returns rc=0');
    assert_single_summary($case, 'normal PASS');
    is($case->{rows}[0]{status}, 'PASS', 'normal PASS summary status');
    is($case->{rows}[0]{rc}, '0', 'normal PASS summary rc');
    is($case->{meta}{subtype}, '', 'normal PASS has no framework subtype');
}

{
    my $case = run_case(module_fail => [{ rc => 2 }]);
    ok(!$case->{error}, 'normal module FAIL does not throw');
    is($case->{rc}, 2, 'normal module FAIL preserves rc=2');
    assert_single_summary($case, 'normal module FAIL');
    is($case->{rows}[0]{status}, 'FAIL', 'normal module FAIL summary status');
    is($case->{meta}{subtype}, '', 'normal module FAIL is not framework_error');
}

{
    my $case = run_case(unavailable => [{ rc => 111 }]);
    ok(!$case->{error}, 'UNAVAILABLE does not throw');
    is($case->{rc}, 111, 'UNAVAILABLE returns rc=111');
    assert_single_summary($case, 'UNAVAILABLE');
    is($case->{rows}[0]{status}, 'UNAVAILABLE', 'UNAVAILABLE summary status');
    is($case->{meta}{subtype}, '', 'UNAVAILABLE has no framework subtype');
}

{
    my @atomic_paths;
    local $Smoker::Result::TEST_BEFORE_ATOMIC_RENAME = sub {
        my ($path) = @_;
        push @atomic_paths, basename($path);
    };
    my $case = run_case(atomic_normal_writers => [{ rc => 0 }]);
    ok(!$case->{error}, 'normal finalization through shared atomic writers succeeds');
    my %seen = map { $_ => 1 } @atomic_paths;
    ok($seen{'rc.code'}, 'normal Runner rc.code uses Result-owned atomic writer');
    ok($seen{'result.meta'}, 'normal Runner result.meta uses Result-owned atomic writer');
    ok($seen{'execution_trail.audit'},
        'normal Runner execution trail uses Result-owned atomic writer');
}

{
    my @atomic_paths;
    local $Smoker::Result::TEST_BEFORE_ATOMIC_RENAME = sub {
        my ($path) = @_;
        push @atomic_paths, basename($path);
    };
    my $case = run_case(
        'atomic_framework_writers',
        [{ rc => 2 }],
        classify_dies => 1,
    );
    assert_framework_failure($case, 'Runner-caught framework exception uses atomic writers');
    my %seen = map { $_ => 1 } @atomic_paths;
    ok($seen{'framework_error.evidence'} || $seen{'framework_error.note'},
        'Runner framework evidence uses Result-owned atomic writer');
    ok($seen{'rc.code'}, 'Runner framework rc.code uses Result-owned atomic writer');
    ok($seen{'result.meta'}, 'Runner framework result.meta uses Result-owned atomic writer');
    ok($seen{'execution_trail.audit'},
        'Runner framework execution trail uses Result-owned atomic writer');
}

for my $fault_case (
    [ before_rc          => 'after run directory exists but before rc.code' ],
    [ meta_open          => 'after rc.code is written but before result.meta is complete' ],
    [ audit_after_meta   => 'after result.meta is written but before summary row is appended' ],
    [ framework_evidence => 'while preparing framework evidence' ],
    [ rc_write           => 'while attempting normal finalization' ],
) {
    my ($fault, $label) = @$fault_case;
    my $attempt = $fault eq 'framework_evidence'
        ? { rc => 137, framework_error => 1, raw_wait_status => 2304 }
        : { rc => 2 };
    my $case = run_case($fault, [$attempt], fault => $fault);
    assert_framework_failure($case, $label);
}

{
    my $case = run_case(classification_exception => [{ rc => 2 }], classify_dies => 1);
    assert_framework_failure($case, 'during ordinary result classification');
}

{
    my $case = run_case(audit_framework_exception => [{ rc => 2 }], fault => 'audit_after_meta');
    assert_framework_failure($case, 'repeated finalization attempt');
    assert_single_summary($case, 'repeated finalization attempt');
}

{
    my $case = run_case(success_not_overwritten => [{ rc => 0 }]);
    ok(!$case->{error}, 'existing successful result scenario completes normally');
    is($case->{rows}[0]{status}, 'PASS',
        'existing successful result is not overwritten as framework failure');
    is($case->{meta}{subtype}, '',
        'existing successful result keeps its non-framework subtype');
}

sub invalid_shared_finalization {
    my (%overrides) = @_;
    my $root = tempdir(CLEANUP => 1);
    my $run_dir = File::Spec->catdir($root, 'runs', '000001');
    make_path($run_dir);

    my %args = (
        run_id => '000001', batch => 'invalid_finalization',
        base => 'perl:5.38', mode => 'baseline',
        module => 'Invalid::Finalization', version => '1.0',
        status => 'FAIL', subtype => 'framework_error', rc => 125,
        start_ts => '2026-01-01T00:00:00Z',
        end_ts => '2026-01-01T00:00:01Z', elapsed_s => '1.000000',
        run_dir => $run_dir,
        summary_file => File::Spec->catfile($root, 'summary.csv'),
        note => 'Framework exception: injected test failure',
        framework_reason => 'injected test failure',
    );
    @args{keys %overrides} = values %overrides;

    my $ok = eval { finalize_result(%args); 1 };
    return ($ok, $@, $root, $run_dir);
}

{
    my ($ok, $error, $root, $run_dir) = invalid_shared_finalization(subtype => '');
    ok(!$ok, 'shared finalizer rejects rc=125 without framework_error subtype');
    like($error, qr/rc=125.*framework_error/i, 'bare rc=125 rejection explains the contract');
    ok(!-e File::Spec->catfile($root, 'summary.csv'), 'invalid rc=125 writes no summary');
    ok(!-e File::Spec->catfile($run_dir, 'rc.code'), 'invalid rc=125 writes no rc.code');
}

{
    my ($ok, $error) = invalid_shared_finalization(rc => 2);
    ok(!$ok, 'shared finalizer rejects framework_error with non-125 rc');
    like($error, qr/framework_error.*rc=125/i, 'non-125 framework rejection explains the contract');
}

{
    my ($ok, $error) = invalid_shared_finalization(framework_reason => '');
    ok(!$ok, 'shared finalizer rejects framework_error without a causal reason');
    like($error, qr/framework.*reason/i, 'missing framework reason rejection explains the contract');
}

{
    my $root = tempdir(CLEANUP => 1);
    my $run_one = File::Spec->catdir($root, 'runs', '000001');
    my $run_two = File::Spec->catdir($root, 'runs', '000002');
    make_path($run_one, $run_two);
    my $summary = File::Spec->catfile($root, 'summary.csv');

    my %common = (
        batch => 'atomic_summary', base => 'perl:5.38', mode => 'baseline',
        version => '1.0', status => 'PASS', subtype => '', rc => 0,
        start_ts => '2026-01-01T00:00:00Z',
        end_ts => '2026-01-01T00:00:01Z', elapsed_s => '1.000000',
        summary_file => $summary, note => '',
    );
    finalize_result(
        %common, run_id => '000001', module => 'Atomic::Existing',
        run_dir => $run_one,
    );
    my $before = read_text($summary);

    my $error = '';
    open my $pending, '>', File::Spec->catfile($run_two, '.summary-row.state')
        or die $!;
    print {$pending} "pending\n";
    close $pending;
    {
        local $Smoker::Result::TEST_BEFORE_SUMMARY_RENAME = sub {
            die "injected crash before summary rename\n";
        };
        eval {
            finalize_result(
                %common, run_id => '000002', module => 'Atomic::New',
                run_dir => $run_two,
            );
            1;
        } or do {
            $error = $@ || 'unknown error';
        };
    }

    like($error, qr/injected crash before summary rename/,
        'summary replacement fault is surfaced');
    is(read_text($summary), $before,
        'crash before atomic summary replacement preserves all existing rows');

    open my $damaged, '>', File::Spec->catfile($run_two, '.summary-row.state')
        or die $!;
    print {$damaged} "damaged\n";
    close $damaged;
    finalize_result(
        %common, run_id => '000002', module => 'Atomic::New',
        run_dir => $run_two,
    );
    my @atomic_rows = grep { /^000002,/ } split /\n/, read_text($summary);
    is(scalar @atomic_rows, 1,
        'damaged summary transaction state is conservatively reconciled once');
}

for my $marker_case (
    [ missing => undef ],
    [ empty   => '' ],
) {
    my ($label, $replacement) = @$marker_case;
    my $root = tempdir(CLEANUP => 1);
    my $run_dir = File::Spec->catdir($root, 'runs', '000001');
    make_path($run_dir);
    my $summary = File::Spec->catfile($root, 'summary.csv');
    my %result = (
        run_id => '000001', batch => 'marker_recovery', base => 'perl:5.38',
        mode => 'baseline', module => 'Marker::Recovery', version => '1.0',
        status => 'PASS', subtype => '', rc => 0, start_ts => 'start',
        end_ts => 'end', elapsed_s => '1.0', run_dir => $run_dir,
        summary_file => $summary, note => '',
    );
    finalize_result(%result);

    my $state = File::Spec->catfile($run_dir, '.summary-row.state');
    if (defined $replacement) {
        open my $fh, '>', $state or die $!;
        print {$fh} $replacement;
        close $fh;
    }
    else {
        unlink $state or die "unlink $state: $!";
    }

    finalize_result(%result);
    my @rows = grep { /^000001,/ } split /\n/, read_text($summary);
    is(scalar @rows, 1,
        "$label transaction marker with an existing row remains idempotent");
}

{
    my $root = tempdir(CLEANUP => 1);
    my $run_dir = File::Spec->catdir($root, 'runs', '000001');
    make_path($run_dir);
    my $summary = File::Spec->catfile($root, 'summary.csv');
    my %result = (
        run_id => '000001', batch => 'append_crash', base => 'perl:5.38',
        mode => 'baseline', module => 'Append::Crash', version => '1.0',
        status => 'PASS', subtype => '', rc => 0, start_ts => 'start',
        end_ts => 'end', elapsed_s => '1.0', run_dir => $run_dir,
        summary_file => $summary, note => '',
    );
    my $error = '';
    {
        local $Smoker::Result::TEST_AFTER_SUMMARY_APPEND = sub {
            die "injected crash after summary append\n";
        };
        eval { finalize_result(%result); 1 } or $error = $@;
    }
    like($error, qr/injected crash after summary append/,
        'crash after append but before index update is surfaced');
    finalize_result(%result);
    my @rows = grep { /^000001,/ } split /\n/, read_text($summary);
    is(scalar @rows, 1,
        'pending append is reconciled to exactly one row after retry');
}

{
    my $root = tempdir(CLEANUP => 1);
    my $run_dir = File::Spec->catdir($root, 'runs', '000001');
    make_path($run_dir);
    my $summary = File::Spec->catfile($root, 'summary.csv');
    my %result = (
        run_id => '000001', batch => 'reconcile_crash', base => 'perl:5.38',
        mode => 'baseline', module => 'Reconcile::Crash', version => '1.0',
        status => 'FAIL', subtype => 'framework_error', rc => 125,
        framework_reason => 'test recovery', start_ts => 'start',
        end_ts => 'end', elapsed_s => '1.0', run_dir => $run_dir,
        summary_file => $summary, note => 'test recovery',
    );
    my $error = '';
    {
        local $Smoker::Result::TEST_AFTER_SUMMARY_RENAME = sub {
            die "injected crash after summary rename\n";
        };
        eval { finalize_result(%result, framework_recovery => 1); 1 }
            or $error = $@;
    }
    like($error, qr/injected crash after summary rename/,
        'crash after recovery rename but before index update is surfaced');
    is(read_text(File::Spec->catfile($run_dir, '.summary-row.state')), "pending\n",
        'reconciliation records pending state before replacing the summary');
    finalize_result(%result);
    my @rows = grep { /^000001,/ } split /\n/, read_text($summary);
    is(scalar @rows, 1,
        'rename-to-index crash is reconciled to exactly one row on ordinary retry');
}

{
    my $root = tempdir(CLEANUP => 1);
    my $run_dir = File::Spec->catdir($root, 'runs', '000001');
    make_path($run_dir);
    my $summary = File::Spec->catfile($root, 'summary.csv');
    open my $fh, '>', $summary or die $!;
    print {$fh} join(',', Smoker::Result::summary_header_fields()), "\n";
    print {$fh} "000001,legacy,perl:5.38,baseline,Legacy::Result,1.0,,,,,PASS,0,start,end,1.0,$run_dir,\n";
    close $fh;

    finalize_result(
        run_id => '000001', batch => 'legacy', base => 'perl:5.38',
        mode => 'baseline', module => 'Legacy::Result', version => '1.0',
        status => 'PASS', subtype => '', rc => 0, start_ts => 'start',
        end_ts => 'end', elapsed_s => '1.0', run_dir => $run_dir,
        summary_file => $summary, note => '',
    );
    my @rows = grep { /^000001,/ } split /\n/, read_text($summary);
    is(scalar @rows, 1,
        'legacy summary without transaction metadata remains idempotent');
}

{
    my $root = tempdir(CLEANUP => 1);
    my $summary = File::Spec->catfile($root, 'summary.csv');
    my $prior_rows = 2_000;

    open my $fh, '>', $summary or die "write $summary: $!";
    print {$fh} join(',', Smoker::Result::summary_header_fields()), "\n";
    for my $id (1 .. $prior_rows) {
        printf {$fh} "%06d,scale,perl:5.38,baseline,Scale::%d,1.0,,,,,PASS,0,start,end,1.0,%s/runs/%06d,\n",
            $id, $id, $root, $id;
    }
    close $fh or die "close $summary: $!";

    my $existing_run_dir = File::Spec->catdir($root, 'runs', '000001');
    make_path($existing_run_dir);
    finalize_result(
        run_id => '000001', batch => 'scale', base => 'perl:5.38',
        mode => 'baseline', module => 'Scale::1', version => '1.0',
        status => 'PASS', subtype => '', rc => 0, start_ts => 'start',
        end_ts => 'end', elapsed_s => '1.0', run_dir => $existing_run_dir,
        summary_file => $summary, note => '',
    );

    my $run_dir = File::Spec->catdir($root, 'runs', sprintf('%06d', $prior_rows + 1));
    make_path($run_dir);
    my $summary_inode = (stat($summary))[1];

    my $historical_rows_parsed = 0;
    my $original_getline_hr = Text::CSV->can('getline_hr');
    {
        no warnings 'redefine';
        no warnings 'once';
        local *Text::CSV::getline_hr = sub {
            $historical_rows_parsed++;
            return $original_getline_hr->(@_);
        };
        finalize_result(
            run_id => sprintf('%06d', $prior_rows + 1), batch => 'scale',
            base => 'perl:5.38', mode => 'baseline', module => 'Scale::New',
            version => '1.0', status => 'PASS', subtype => '', rc => 0,
            start_ts => 'start', end_ts => 'end', elapsed_s => '1.0',
            run_dir => $run_dir, summary_file => $summary, note => '',
        );
    }

    is((stat($summary))[1], $summary_inode,
        'ordinary first-time summary insertion appends without replacing the prior summary');
    is($historical_rows_parsed, 0,
        'ordinary first-time insertion does not parse historical summary rows');
    is(scalar(@{ summary_rows($root) }), $prior_rows + 1,
        'synthetic scale insertion appends exactly one summary row');
}

done_testing;
