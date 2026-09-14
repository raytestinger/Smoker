package Smoker::Scheduler;
use strict;
use warnings;

use File::Basename qw(basename);
use File::Path qw(make_path);
use Log::Log4perl;
use Text::CSV;
use Time::HiRes qw(time sleep);
use Fcntl qw(:flock);
use File::Spec;
use POSIX qw(WNOHANG);
use Smoker::Runner ();
use Smoker::Result qw(
    classify_result
    decode_wait_status
    finalize_result
    inspect_result
    iso8601_utc
    single_line_reason
);

my $log = Log::Log4perl->get_logger(__PACKAGE__);

our $TEST_AFTER_FORK;
our $TEST_AFTER_REAP;
our $TEST_FORK;

sub run_plan_csv {
    my (%args) = @_;

    my $smoker_root = $args{smoker_root};
    my $plan_csv    = $args{plan};
    my $suite_root  = $args{suite_root};

    $log->debug('entered run_plan_csv');

    unless (defined $smoker_root && $smoker_root ne '') {
        $log->error('missing smoker_root');
        die "missing smoker_root\n";
    }

    unless (defined $plan_csv && $plan_csv ne '') {
        $log->error('missing plan');
        die "missing plan\n";
    }

    unless (defined $suite_root && $suite_root ne '') {
        $log->error('missing suite_root');
        die "missing suite_root\n";
    }

    $log->info(
        "scheduler start smoker_root=$smoker_root " .
        "plan=$plan_csv suite_root=$suite_root"
    );

    unless (-d $suite_root) {
        $log->debug("creating suite root $suite_root");
        make_path($suite_root);
    }

    my $lock_path = File::Spec->catfile($suite_root, '.scheduler.lock');
    open my $lock_fh, '>>', $lock_path
        or die "cannot open suite lock $lock_path: $!
";
    unless (flock($lock_fh, LOCK_EX | LOCK_NB)) {
        die "suite is already being executed by another scheduler: $suite_root
";
    }
    seek($lock_fh, 0, 0);
    truncate($lock_fh, 0);
    print {$lock_fh} "pid=$$ started=" . scalar(localtime()) . "
";

    my @rows = read_plan_csv($plan_csv);

    unless (@rows) {
        $log->error("no usable rows in $plan_csv");
        die "no usable rows in $plan_csv\n";
    }

    my $batch = basename($suite_root);

    my %kind_count;

    my $max_jobs =
        $args{jobs}
        || $ENV{SMOKER_JOBS}
        || 8;

    if (
        !defined $max_jobs
        || $max_jobs !~ /^\d+$/
        || $max_jobs <= 0
    ) {
        $log->warn('invalid max_jobs value; using default of 8');
        $max_jobs = 8;
    }

    for my $r (@rows) {
        $kind_count{$r->{mode}}++;
    }

    my $kind_summary = join(
        ', ',
        map { "$_=$kind_count{$_}" } sort keys %kind_count
    );

    $log->info(
        'plan loaded ' .
        'batch=' . $batch .
        ' rows=' . scalar(@rows) .
        " max_jobs=$max_jobs" .
        ($kind_summary ne '' ? " row_kinds=[$kind_summary]" : '')
    );

    local $| = 1;

    print "INFO: runroot=$suite_root\n";
    print "INFO: rows=", scalar(@rows), "\n";
    print "INFO: max_jobs=$max_jobs\n";

    my %children;
    my $stopping = 0;

    my $stop_signal = '';
    local $SIG{INT} = sub {
        $stopping = 1;
        $stop_signal = 'INT';
        _signal_children(\%children, 'INT');
    };
    local $SIG{TERM} = sub {
        $stopping = 1;
        $stop_signal = 'TERM';
        _signal_children(\%children, 'TERM');
    };
    my %totals = (
        pass        => 0,
        fail        => 0,
        unavailable => 0,
        other       => 0,
    );
    my $started_at = time();
    my $seq = 0;

    my $row_index = 0;
    for (; $row_index < @rows; $row_index++) {
        my $r = $rows[$row_index];
        last if $stopping;
        while (scalar(keys %children) >= $max_jobs) {
            $log->debug(
                'maximum active children reached; waiting for one child ' .
                'active=' . scalar(keys %children)
            );
            reap_one(\%children, \%totals);
            last if $stopping;
        }
        last if $stopping;

        $seq++;

        my $run_dir = reserve_run_dir(
            suite_root => $suite_root,
            run_id     => $seq,
        );

        my $child_record = {
            seq     => $seq,
            module  => ($r->{module} // ''),
            version => ($r->{version} // ''),
            mode    => ($r->{mode} // ''),
            base    => ($r->{base} // ''),
            run_dir => $run_dir,
            suite_root => $suite_root,
            batch   => $batch,
            row     => { %$r },
            dispatched_at => time(),
        };

        my $pid = $TEST_FORK ? $TEST_FORK->() : fork();

        unless (defined $pid) {
            $log->error("fork failed for row $seq: $!");
            recover_child_result(
                child      => $child_record,
                suite_root => $suite_root,
                batch      => $batch,
                reason     => "fork failed after run-directory reservation: $!",
                stage      => 'fork',
            );
            die "fork failed: $!";
        }

        if ($pid == 0) {
            setpgrp(0, 0);
            my $child_pid = $$;

            my $mode    = $r->{mode};
            my $module  = $r->{module};
            my $version = $r->{version};
            my $base    = $r->{base};
            my $timeout = $args{timeout} || $ENV{SMOKER_RUN_TIMEOUT} || 1800;

            my $ver_disp =
                defined $version && $version ne ''
                ? $version
                : 'latest';

            $log->info(
                "row start seq=$seq child_pid=$child_pid " .
                "module=$module version=$ver_disp mode=$mode " .
                "base=$base timeout=$timeout"
            );

            my $runner = Smoker::Runner->new(
                smoker_root => $smoker_root,
                batch       => $batch,
                outdir      => $suite_root,
                mode        => $mode,
                base        => $base,
                timeout     => $timeout,
            );

            my $rc = $runner->run_one(
                run_id          => $seq,
                module          => $module,
                version         => $version,
                mode            => $mode,
                base            => $base,
                timeout         => $timeout,
                assigned_run_dir => $run_dir,
                dep_one         => ($r->{dep_one}         // ''),
                dep_one_version => ($r->{dep_one_version} // ''),
                dep_two         => ($r->{dep_two}         // ''),
                dep_two_version => ($r->{dep_two_version} // ''),
                note            => build_note_from_row($r),
            );

            my $dep_txt = '';

            if (($mode || '') eq 'vary-one') {
                my $d1 = defined $r->{dep_one}         ? $r->{dep_one}         : '';
                my $v1 = defined $r->{dep_one_version} ? $r->{dep_one_version} : '';
                $dep_txt = " dep_one=$d1 dep_one_version=$v1";
            }
            elsif (($mode || '') eq 'vary-two') {
                my $d1 = defined $r->{dep_one}         ? $r->{dep_one}         : '';
                my $v1 = defined $r->{dep_one_version} ? $r->{dep_one_version} : '';
                my $d2 = defined $r->{dep_two}         ? $r->{dep_two}         : '';
                my $v2 = defined $r->{dep_two_version} ? $r->{dep_two_version} : '';

                $dep_txt =
                    " dep_one=$d1 dep_one_version=$v1" .
                    " dep_two=$d2 dep_two_version=$v2";
            }

            $log->info(
                "row finish seq=$seq child_pid=$child_pid rc=$rc " .
                "module=$module version=$ver_disp mode=$mode base=$base$dep_txt"
            );

            exit($rc & 255);
        }

        $child_record->{pid} = $pid;
        $children{$pid} = $child_record;

        $TEST_AFTER_FORK->(
            pid      => $pid,
            children => \%children,
            row      => $r,
            run_dir  => $run_dir,
        ) if $TEST_AFTER_FORK;

        $log->debug(
            "forked row seq=$seq child_pid=$pid " .
            'active=' . scalar(keys %children)
        );
    }

    if ($stopping) {
        _stop_children(\%children, $stop_signal || 'TERM');

        for my $remaining_index ($row_index .. $#rows) {
            my $r = $rows[$remaining_index];
            $seq++;
            my $run_dir = reserve_run_dir(
                suite_root => $suite_root,
                run_id     => $seq,
            );
            recover_child_result(
                child => {
                    seq       => $seq,
                    module    => ($r->{module} // ''),
                    version   => ($r->{version} // ''),
                    mode      => ($r->{mode} // ''),
                    base      => ($r->{base} // ''),
                    run_dir   => $run_dir,
                    suite_root => $suite_root,
                    batch     => $batch,
                    row       => { %$r },
                    dispatched_at => time(),
                },
                reason => "scheduler interrupted by SIG" . ($stop_signal || 'TERM')
                    . ' before worker dispatch',
                stage  => 'scheduler_interrupt',
            );
        }

        die "scheduler interrupted by SIG" . ($stop_signal || 'TERM') . "\n";
    }

    while (scalar(keys %children)) {
        reap_one(\%children, \%totals);
    }

    my $elapsed_s = time() - $started_at;
    my $total =
        $totals{pass}
        + $totals{fail}
        + $totals{unavailable}
        + $totals{other};

    $log->info(
        'scheduler summary ' .
        "batch=$batch total=$total " .
        "pass=$totals{pass} fail=$totals{fail} " .
        "unavailable=$totals{unavailable} other=$totals{other} " .
        sprintf('elapsed_s=%.3f', $elapsed_s)
    );

    $log->info(
        'scheduler complete ' .
        "batch=$batch rows=" . scalar(@rows)
    );

    return;
}

sub reap_one {
    my ($children, $totals) = @_;

    my $done = wait();

    if ($done < 1) {
        $log->debug('wait returned no completed child');
        return;
    }

    my $child = $children->{$done};
    my $seq = ref($child) eq 'HASH' ? $child->{seq} : $child;
    my $module = ref($child) eq 'HASH' ? ($child->{module} // '') : '';
    my $version = ref($child) eq 'HASH' ? ($child->{version} // '') : '';
    my $mode = ref($child) eq 'HASH' ? ($child->{mode} // '') : '';
    my $status = $?;
    my $decoded = decode_wait_status($status);
    my $exit_code = $decoded->{exit_code};
    my $signal = $decoded->{signal};
    my $core_dumped = $decoded->{core_dumped};

    my $inspection;
    my $needs_recovery = 0;
    my $recovery_reason = '';

    if (ref($child) eq 'HASH') {
        $inspection = inspect_result(
            run_id       => sprintf('%06d', $seq),
            run_dir      => $child->{run_dir},
            summary_file => File::Spec->catfile($child->{suite_root}, 'summary.csv'),
        );

        if ($signal || $core_dumped) {
            $needs_recovery = 1;
            $recovery_reason = $signal
                ? "worker terminated by signal $signal"
                : 'worker terminated with core dump';
        }
        elsif (!$inspection->{complete}) {
            $needs_recovery = 1;
            $recovery_reason =
                'worker exited without complete consistent result: '
                . join('; ', @{ $inspection->{issues} || [] });
        }

        if ($needs_recovery) {
            recover_child_result(
                child           => $child,
                reason          => $recovery_reason,
                stage           => 'reap',
                worker_pid      => $done,
                raw_wait_status => $decoded->{raw_wait_status},
                exit_code       => $decoded->{exit_code},
                signal          => $decoded->{signal},
                core_dumped     => $decoded->{core_dumped},
            );
            $inspection = inspect_result(
                run_id       => sprintf('%06d', $seq),
                run_dir      => $child->{run_dir},
                summary_file => File::Spec->catfile($child->{suite_root}, 'summary.csv'),
            );
        }
    }
    else {
        $needs_recovery = 1;
        $recovery_reason = "reaped unknown worker pid=$done";
    }

    delete $children->{$done};

    $TEST_AFTER_REAP->(
        pid      => $done,
        child    => $child,
        children => $children,
        status   => $status,
    ) if $TEST_AFTER_REAP;

    my $reported_rc =
        $inspection && $inspection->{complete}
        ? $inspection->{rc}
        : ($signal || $core_dumped) ? 125 : $exit_code;
    my $result = classify_result(rc => $reported_rc)->{status};

    if ($result eq 'PASS') {
        $totals->{pass}++;
    }
    elsif ($result eq 'UNAVAILABLE') {
        $totals->{unavailable}++;
    }
    else {
        $totals->{fail}++;
    }

    my $version_text = length($version) ? " version=$version" : '';
    my $mode_text = length($mode) ? " mode=$mode" : '';
    my $signal_text = $signal ? " signal=$signal" : '';

    printf "RESULT: run=%06d status=%-11s module=%s%s%s rc=%d%s\n",
        (defined $seq ? $seq : 0),
        $result,
        (length($module) ? $module : '(unknown)'),
        $version_text,
        $mode_text,
        $reported_rc,
        $signal_text;

    $log->debug(
        'reaped child ' .
        "seq=" . (defined $seq ? $seq : 'unknown') .
        " child_pid=$done exit_code=$exit_code signal=$signal " .
        "core_dumped=$core_dumped active=" . scalar(keys %$children)
    );

    return;
}

sub recover_child_result {
    my (%args) = @_;

    my $child = $args{child};
    die "recover_child_result missing child record\n"
        unless ref($child) eq 'HASH';

    my $run_dir = $child->{run_dir};
    die "recover_child_result missing assigned run directory\n"
        unless defined $run_dir && $run_dir ne '';
    die "recover_child_result assigned run directory is not reserved: $run_dir\n"
        unless -d $run_dir;

    my $row = $child->{row} || {};
    my $seq = $child->{seq};
    my $run_id = sprintf('%06d', $seq);
    my $suite_root = $args{suite_root}
        // $child->{suite_root}
        // File::Spec->catdir($run_dir, '..', '..');
    my $summary_file = File::Spec->catfile($suite_root, 'summary.csv');
    my $batch = $args{batch}
        // $child->{batch}
        // (File::Spec->splitdir($suite_root))[-1];

    my $decoded = {
        raw_wait_status => $args{raw_wait_status},
        exit_code       => $args{exit_code},
        signal          => $args{signal},
        core_dumped     => $args{core_dumped},
    };

    my $reason = single_line_reason(
        $args{reason},
        'worker could not finalize assigned plan row',
    );
    my $stage = single_line_reason($args{stage}, 'scheduler_recovery');
    my $now = time();
    my $start = $child->{dispatched_at} // $now;
    my $signal = $decoded->{signal};
    my $note = "Framework recovery at $stage: $reason";

    return finalize_result(
        run_id          => $run_id,
        batch           => $batch,
        base            => $child->{base} // $row->{base} // '',
        mode            => $child->{mode} // $row->{mode} // '',
        module          => $child->{module} // $row->{module} // '',
        version         => $child->{version} // $row->{version} // '',
        dep_one         => $row->{dep_one} // '',
        dep_one_version => $row->{dep_one_version} // '',
        dep_two         => $row->{dep_two} // '',
        dep_two_version => $row->{dep_two_version} // '',
        status          => 'FAIL',
        subtype         => 'framework_error',
        rc              => 125,
        start_ts        => iso8601_utc($start),
        end_ts          => iso8601_utc($now),
        elapsed_s       => sprintf('%.6f', $now - $start),
        run_dir         => $run_dir,
        summary_file    => $summary_file,
        note            => $note,
        framework_reason => $reason,
        stage           => $stage,
        worker_pid      => $args{worker_pid} // $child->{pid} // '',
        raw_return_code => (
            defined($decoded->{exit_code}) && $decoded->{exit_code} ne ''
            ? $decoded->{exit_code}
            : ''
        ),
        raw_wait_status => $decoded->{raw_wait_status},
        interrupted     => ($signal ? 1 : 0),
        interrupt_signal => ($signal // ''),
        core_dumped     => $decoded->{core_dumped},
        framework_recovery => 1,
    );
}

sub reserve_run_dir {
    my (%args) = @_;

    my $suite_root = $args{suite_root};
    my $run_id     = $args{run_id};

    die "reserve_run_dir missing suite_root\n"
        unless defined $suite_root && $suite_root ne '';
    die "reserve_run_dir missing run_id\n"
        unless defined $run_id && $run_id =~ /\A\d+\z/;

    my $runs_root = File::Spec->catdir($suite_root, 'runs');
    make_path($runs_root) unless -d $runs_root;

    my $run_dir = File::Spec->catdir($runs_root, sprintf('%06d', $run_id));

    die "run directory already exists; refusing to reuse reserved path: $run_dir\n"
        if -e $run_dir;

    mkdir $run_dir
        or die "cannot reserve run directory $run_dir: $!\n";

    return $run_dir;
}

sub _stop_children {
    my ($children, $signal) = @_;
    return unless $children && %$children;

    _signal_children($children, $signal);

    my $deadline = time() + 5;
    my %wait_status;
    while (%$children && time() < $deadline) {
        for my $pid (keys %$children) {
            my $done = waitpid($pid, WNOHANG);
            $wait_status{$pid} = $? if $done == $pid;
        }
        last if keys(%wait_status) == keys(%$children);
        sleep 0.1;
    }

    for my $pid (keys %$children) {
        next if exists $wait_status{$pid};
        kill 'KILL', -$pid;
        waitpid($pid, 0);
        $wait_status{$pid} = $?;
    }

    for my $pid (keys %$children) {
        my $child = $children->{$pid};
        my $inspection = inspect_result(
            run_id       => sprintf('%06d', $child->{seq}),
            run_dir      => $child->{run_dir},
            summary_file => File::Spec->catfile($child->{suite_root}, 'summary.csv'),
        );
        my $completed_from_interrupt =
            $inspection->{complete}
            && ($inspection->{interrupted} // '') eq '1';
        if (!$inspection->{complete} || $completed_from_interrupt) {
            my $decoded = decode_wait_status($wait_status{$pid});
            recover_child_result(
                child           => $child,
                reason          => "scheduler interrupted by SIG$signal while worker was active"
                    . ($completed_from_interrupt
                        ? '; worker finalized the caught scheduler signal'
                        : ''),
                stage           => 'scheduler_interrupt',
                worker_pid      => $pid,
                raw_wait_status => $decoded->{raw_wait_status},
                exit_code       => $decoded->{exit_code},
                signal          => $decoded->{signal},
                core_dumped     => $decoded->{core_dumped},
            );
        }
        delete $children->{$pid};
    }
}

sub _signal_children {
    my ($children, $signal) = @_;
    return unless $children && %$children;
    kill $signal, -$_ for keys %$children;
}

sub build_note_from_row {
    # Dependency information is passed to Runner as structured fields.
    # Runner/Smoker::Notes owns all user-visible dependency wording.
    return '';
}

sub read_plan_csv {
    my ($path) = @_;

    $log->debug("opening plan CSV $path");

    open my $fh, '<', $path or do {
        $log->error("open $path failed: $!");
        die "open $path: $!";
    };

    my $csv = Text::CSV->new({
        binary           => 1,
        auto_diag        => 1,
        allow_whitespace => 1,
        blank_is_undef   => 0,
    });

    my $header = $csv->getline($fh);

    unless ($header && @$header) {
        $log->error("missing header in $path");
        die "missing header in $path\n";
    }

    my @expected_cols = qw(
        base mode module version
        dep_one dep_one_version dep_two dep_two_version
    );

    my @cols = @$header;

    if (
        @cols != @expected_cols
        || join("\0", @cols) ne join("\0", @expected_cols)
    ) {
        my $found = join(',', @cols);
        my $expected = join(',', @expected_cols);
        $log->error(
            "invalid plan header in $path: expected [$expected], found [$found]"
        );
        die "invalid plan header in $path\n" .
            "expected: $expected\n" .
            "found:    $found\n";
    }

    my @rows;
    my $line_number = 1;
    my $comment_rows = 0;
    my $blank_rows = 0;

    $log->debug('plan columns: ' . join(', ', @cols));

    while (my $row = $csv->getline($fh)) {
        $line_number++;
        next unless @$row;

        my $first = defined $row->[0] ? $row->[0] : '';
        if ($first =~ /^\s*#/) {
            $comment_rows++;
            next;
        }

        my $all_blank = 1;
        for my $v (@$row) {
            if (defined $v && $v =~ /\S/) {
                $all_blank = 0;
                last;
            }
        }

        if ($all_blank) {
            $blank_rows++;
            next;
        }

        if (@$row != @cols) {
            my $count = scalar @$row;
            my $expected = scalar @cols;
            $log->error(
                "invalid column count in $path line $line_number: " .
                "expected $expected, found $count"
            );
            die "invalid column count in $path line $line_number: " .
                "expected $expected, found $count\n";
        }

        my %h;
        @h{@cols} = @$row;

        unless ($h{base} ne '' && $h{module} ne '') {
            $log->error("missing base or module in $path line $line_number");
            die "missing base or module in $path line $line_number\n";
        }

        unless ($h{mode} =~ /\A(?:baseline|vary-one|vary-two)\z/) {
            $log->error(
                "invalid mode '$h{mode}' in $path line $line_number"
            );
            die "invalid mode '$h{mode}' in $path line $line_number\n";
        }

        push @rows, \%h;
    }

    close $fh or do {
        $log->error("close $path failed: $!");
        die "close $path: $!";
    };

    $log->info(
        "plan CSV read path=$path usable_rows=" . scalar(@rows) .
        " comment_rows=$comment_rows blank_rows=$blank_rows"
    );

    return @rows;
}

1;
