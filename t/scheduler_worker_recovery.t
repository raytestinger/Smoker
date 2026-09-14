use strict;
use warnings;

use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempdir);
use POSIX qw(_exit);
use Test::More;
use Text::CSV;

use lib 'lib';
use Smoker::Scheduler ();
use Smoker::Runner ();
use Smoker::Result qw(decode_wait_status);

{
    package SchedulerReservationTestRunner;
    use parent 'Smoker::Runner';

    sub _run_docker_attempt {
        my ($self, %args) = @_;

        open my $cmd, '>', $args{cmd_file} or die $!;
        print {$cmd} "fake docker command\n";
        close $cmd or die $!;

        open my $out, '>', $args{run_out} or die $!;
        print {$out} "fake execution\n";
        close $out or die $!;

        return { rc => $self->{test_rc} // 0 };
    }
}

sub write_plan {
    my ($path, @modules) = @_;

    open my $fh, '>', $path or die "write $path: $!";
    print {$fh} "base,mode,module,version,dep_one,dep_one_version,dep_two,dep_two_version\n";
    for my $module (@modules) {
        print {$fh} "perl:5.38,baseline,$module,1.0,,,,\n";
    }
    close $fh or die "close $path: $!";
}

sub append_line {
    my ($path, $line) = @_;
    open my $fh, '>>', $path or die "append $path: $!";
    print {$fh} $line, "\n";
    close $fh or die "close $path: $!";
}

sub read_lines {
    my ($path) = @_;
    return () unless -f $path;
    open my $fh, '<', $path or die "read $path: $!";
    my @lines = map { chomp; $_ } <$fh>;
    close $fh;
    return @lines;
}

sub immediate_run_dirs {
    my ($suite) = @_;
    my $runs = File::Spec->catdir($suite, 'runs');
    return () unless -d $runs;

    opendir my $dh, $runs or die "opendir $runs: $!";
    my @dirs = sort grep {
        $_ ne '.' && $_ ne '..'
            && -d File::Spec->catdir($runs, $_)
    } readdir $dh;
    closedir $dh;
    return @dirs;
}

sub summary_rows {
    my ($outdir) = @_;

    my $path = File::Spec->catfile($outdir, 'summary.csv');
    return [] unless -f $path;
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

sub read_text {
    my ($path) = @_;
    return undef unless -f $path;
    open my $fh, '<', $path or die "read $path: $!";
    local $/;
    my $text = <$fh>;
    close $fh;
    return $text;
}

sub read_meta {
    my ($run_dir) = @_;
    my $text = read_text(File::Spec->catfile($run_dir, 'result.meta')) // '';
    my %meta;
    for my $line (split /\r?\n/, $text) {
        next unless $line =~ /\A([^=]+)=(.*)\z/;
        $meta{$1} = $2;
    }
    return \%meta;
}

sub write_text {
    my ($path, $text) = @_;
    open my $fh, '>', $path or die "write $path: $!";
    print {$fh} $text;
    close $fh or die "close $path: $!";
}

sub summary_header {
    return join(',', qw(
        run_id batch base mode module version
        dep_one dep_one_version dep_two dep_two_version
        status rc start_ts end_ts elapsed_s run_dir note
    )) . "\n";
}

sub write_complete_result {
    my (%args) = @_;

    my $suite = $args{suite};
    my $run_dir = $args{run_dir};
    my $run_id = $args{run_id} // '000001';
    my $module = $args{module} // 'Complete::Result';
    my $status = $args{status};
    my $rc = $args{rc};
    my $subtype = $args{subtype} // '';
    my $note = $args{note} // '';
    my $batch = (File::Spec->splitdir($suite))[-1];

    write_text(File::Spec->catfile($run_dir, 'rc.code'), "$rc\n");
    write_text(File::Spec->catfile($run_dir, '00_command.txt'), "fake command\n");
    write_text(
        File::Spec->catfile($run_dir, 'result.meta'),
        join("\n",
            "run_id=$run_id",
            "batch=$batch",
            "base=perl:5.38",
            "mode=baseline",
            "module=$module",
            "version=1.0",
            "dep_one=",
            "dep_one_version=",
            "dep_two=",
            "dep_two_version=",
            "status=$status",
            "subtype=$subtype",
            "rc=$rc",
            "start_ts=2026-01-01T00:00:00Z",
            "end_ts=2026-01-01T00:00:01Z",
            "elapsed_s=1.000000",
            "run_dir=$run_dir",
            "note=$note",
            "raw_return_code=$rc",
            "raw_wait_status=",
            "interrupted=0",
            "interrupt_signal=",
        ) . "\n",
    );
    write_text(
        File::Spec->catfile($run_dir, 'execution_trail.audit'),
        "record=framework_execution_trail\n"
            . "scope=factual_producer_execution_record\n"
            . "run_id=$run_id\n"
            . "run_dir=$run_dir\n"
            . "rc_file=rc.code\n"
            . "result_meta=result.meta\n"
            . "summary_file=summary.csv\n",
    );
    write_text(
        File::Spec->catfile($run_dir, 'framework_error.evidence'),
        "framework worker exception\n",
    ) if $subtype eq 'framework_error';

    my $summary = File::Spec->catfile($suite, 'summary.csv');
    my $csv = Text::CSV->new({ binary => 1, eol => "\n" });
    open my $sfh, '>>', $summary or die "append $summary: $!";
    $csv->print($sfh, [
        $run_id, $batch, 'perl:5.38', 'baseline', $module, '1.0',
        '', '', '', '', $status, $rc,
        '2026-01-01T00:00:00Z', '2026-01-01T00:00:01Z',
        '1.000000', $run_dir, $note,
    ]);
    close $sfh or die "close $summary: $!";
}

sub run_scheduler_recovery_case {
    my (%args) = @_;

    my $root = tempdir(CLEANUP => 1);
    my $suite = File::Spec->catdir($root, 'suite');
    my $plan = File::Spec->catfile($root, 'plan.csv');
    my $module = $args{module} // 'Recover::Case';
    write_plan($plan, $module);

    my $fork_log = File::Spec->catfile($root, 'fork.log');
    my $reap_log = File::Spec->catfile($root, 'reap.log');
    my $error = '';

    {
        no warnings 'redefine';
        local *Smoker::Runner::run_one = sub {
            my ($self, %run_args) = @_;
            my $run_dir = $run_args{assigned_run_dir};
            my $fault = $args{fault} // 'none';

            if ($fault eq 'missing_rc') {
                write_text(File::Spec->catfile($run_dir, 'result.meta'), "status=FAIL\nrc=2\n");
                _exit(2);
            }
            elsif ($fault eq 'malformed_rc') {
                write_text(File::Spec->catfile($run_dir, 'rc.code'), "not-an-int\n");
                _exit(2);
            }
            elsif ($fault eq 'missing_meta') {
                write_text(File::Spec->catfile($run_dir, 'rc.code'), "2\n");
                _exit(2);
            }
            elsif ($fault eq 'bad_meta') {
                write_text(File::Spec->catfile($run_dir, 'rc.code'), "2\n");
                write_text(File::Spec->catfile($run_dir, 'result.meta'), "this is not meta\n");
                _exit(2);
            }
            elsif ($fault eq 'missing_summary') {
                write_complete_result(
                    suite => $self->{outdir}, run_dir => $run_dir,
                    module => $run_args{module}, status => 'FAIL', rc => 2,
                );
                my $summary = File::Spec->catfile($self->{outdir}, 'summary.csv');
                write_text($summary, summary_header());
                _exit(2);
            }
            elsif ($fault eq 'duplicate_summary') {
                write_complete_result(
                    suite => $self->{outdir}, run_dir => $run_dir,
                    module => $run_args{module}, status => 'FAIL', rc => 2,
                );
                write_complete_result(
                    suite => $self->{outdir}, run_dir => $run_dir,
                    module => $run_args{module}, status => 'FAIL', rc => 2,
                );
                _exit(2);
            }
            elsif ($fault eq 'summary_status_mismatch') {
                write_complete_result(
                    suite => $self->{outdir}, run_dir => $run_dir,
                    module => $run_args{module}, status => 'FAIL', rc => 2,
                );
                my $summary = File::Spec->catfile($self->{outdir}, 'summary.csv');
                my $text = read_text($summary);
                $text =~ s/,FAIL,2,/,PASS,2,/;
                write_text($summary, $text);
                _exit(2);
            }
            elsif ($fault eq 'summary_rc_mismatch') {
                write_complete_result(
                    suite => $self->{outdir}, run_dir => $run_dir,
                    module => $run_args{module}, status => 'FAIL', rc => 2,
                );
                my $summary = File::Spec->catfile($self->{outdir}, 'summary.csv');
                my $text = read_text($summary);
                $text =~ s/,FAIL,2,/,FAIL,125,/;
                write_text($summary, $text);
                _exit(2);
            }
            elsif ($fault eq 'missing_framework_reason') {
                write_complete_result(
                    suite => $self->{outdir}, run_dir => $run_dir,
                    module => $run_args{module}, status => 'FAIL', rc => 125,
                    subtype => 'framework_error',
                );
                write_text(File::Spec->catfile($run_dir, 'framework_error.evidence'), "\n");
                _exit(125);
            }
            elsif ($fault eq 'missing_framework_evidence') {
                write_complete_result(
                    suite => $self->{outdir}, run_dir => $run_dir,
                    module => $run_args{module}, status => 'FAIL', rc => 125,
                    subtype => 'framework_error',
                );
                unlink File::Spec->catfile($run_dir, 'framework_error.evidence');
                _exit(125);
            }
            elsif ($fault eq 'partial_normal') {
                write_text(File::Spec->catfile($run_dir, 'rc.code'), "0\n");
                write_text(File::Spec->catfile($run_dir, 'result.meta'), "status=PASS\nrc=0\n");
                _exit(0);
            }
            elsif ($fault eq 'outside_runner_exception') {
                _exit(255);
            }
            elsif ($fault eq 'signal') {
                kill 'TERM', $$;
                sleep 5;
                _exit(1);
            }
            elsif ($fault eq 'complete_pass') {
                write_complete_result(
                    suite => $self->{outdir}, run_dir => $run_dir,
                    module => $run_args{module}, status => 'PASS', rc => 0,
                );
                return 0;
            }
            elsif ($fault eq 'complete_fail') {
                write_complete_result(
                    suite => $self->{outdir}, run_dir => $run_dir,
                    module => $run_args{module}, status => 'FAIL', rc => 2,
                );
                return 2;
            }
            elsif ($fault eq 'complete_unavailable') {
                write_complete_result(
                    suite => $self->{outdir}, run_dir => $run_dir,
                    module => $run_args{module}, status => 'UNAVAILABLE', rc => 111,
                );
                return 111;
            }
            elsif ($fault eq 'complete_framework') {
                write_complete_result(
                    suite => $self->{outdir}, run_dir => $run_dir,
                    module => $run_args{module}, status => 'FAIL', rc => 125,
                    subtype => 'framework_error',
                    note => 'already recovered framework failure',
                );
                return 125;
            }

            _exit(9);
        };

        local $Smoker::Scheduler::TEST_AFTER_FORK = sub {
            my (%hook) = @_;
            my $child = $hook{children}->{ $hook{pid} };
            append_line($fork_log, join "\t",
                $hook{pid}, $child->{seq}, $child->{run_dir});
        };
        local $Smoker::Scheduler::TEST_AFTER_REAP = sub {
            my (%hook) = @_;
            append_line($reap_log, join "\t",
                $hook{pid},
                exists($hook{children}->{ $hook{pid} }) ? 'still_mapped' : 'removed',
            );
        };

        eval {
            Smoker::Scheduler::run_plan_csv(
                smoker_root => '.',
                plan        => $plan,
                suite_root  => $suite,
                jobs        => 1,
            );
            1;
        } or do {
            $error = $@ || 'unknown error';
        };
    }

    my $run_dir = File::Spec->catdir($suite, 'runs', '000001');
    return {
        root => $root,
        suite => $suite,
        run_dir => $run_dir,
        error => $error,
        rows => summary_rows($suite),
        meta => read_meta($run_dir),
        rc_text => read_text(File::Spec->catfile($run_dir, 'rc.code')),
        evidence => (
            read_text(File::Spec->catfile($run_dir, 'framework_error.evidence'))
            // read_text(File::Spec->catfile($run_dir, 'framework_error.note'))
            // ''
        ),
        fork_log => $fork_log,
        reap_log => $reap_log,
    };
}

sub assert_recovered_framework_result {
    my ($case, $label) = @_;

    is($case->{rc_text}, "125\n", "$label: rc.code is repaired to 125");
    is($case->{meta}{status}, 'FAIL', "$label: result.meta status is FAIL");
    is($case->{meta}{rc}, '125', "$label: result.meta rc is 125");
    is($case->{meta}{subtype}, 'framework_error', "$label: subtype is framework_error");
    like($case->{meta}{note} // '', qr/\S/, "$label: framework reason is nonempty");
    is(scalar(@{ $case->{rows} }), 1, "$label: exactly one summary row remains");
    is($case->{rows}[0]{status}, 'FAIL', "$label: summary status is FAIL");
    is($case->{rows}[0]{rc}, '125', "$label: summary rc is 125");
    is($case->{rows}[0]{run_dir}, $case->{run_dir},
        "$label: recovery uses the assigned run directory");
    like($case->{evidence}, qr/framework|worker|signal|exception/i,
        "$label: framework evidence is present");
    ok(-s File::Spec->catfile($case->{run_dir}, 'execution_trail.audit'),
        "$label: execution trail is present");
    is_deeply([immediate_run_dirs($case->{suite})], ['000001'],
        "$label: no replacement run directory is allocated");
}

sub make_validator_recovery_fixture {
    my (%args) = @_;

    my $root = tempdir(CLEANUP => 1);
    my $suite = File::Spec->catdir($root, 'suite');
    my $runs = File::Spec->catdir($suite, 'runs');
    my $run_dir = File::Spec->catdir($runs, '000001');
    make_path($run_dir);

    my $plan_text =
        "base,mode,module,version,dep_one,dep_one_version,dep_two,dep_two_version\n"
        . "perl:5.38,baseline,Validator::Recovered,1.0,,,,\n";
    write_text(File::Spec->catfile($suite, 'original_plan.csv'), $plan_text);
    write_text(File::Spec->catfile($suite, 'plan_deduplicated.csv'), $plan_text);
    write_text(
        File::Spec->catfile($suite, 'skipped_dup.csv'),
        "base,mode,module,version,dep_one,dep_one_version,dep_two,dep_two_version\n",
    );
    write_text(File::Spec->catfile($suite, 'batch_info.txt'), "batch=suite\n");
    write_text(
        File::Spec->catfile($suite, 'result_classification_audit.txt'),
        "Classification evidence: PASS\nClassified: 1\nUnclassified: 0\n",
    );

    Smoker::Scheduler::recover_child_result(
        child => {
            seq     => 1,
            module  => 'Validator::Recovered',
            version => '1.0',
            mode    => 'baseline',
            base    => 'perl:5.38',
            run_dir => $run_dir,
            suite_root => $suite,
            batch   => 'suite',
            row     => {
                base => 'perl:5.38', mode => 'baseline',
                module => 'Validator::Recovered', version => '1.0',
                dep_one => '', dep_one_version => '',
                dep_two => '', dep_two_version => '',
            },
            dispatched_at => time(),
        },
        reason => 'validator fixture worker exit without artifacts',
        stage  => 'validator_fixture',
        worker_pid => 4242,
        raw_wait_status => 2304,
        exit_code => 9,
        signal => 0,
        core_dumped => 0,
    );

    if ($args{corrupt}) {
        write_text(File::Spec->catfile($run_dir, 'framework_error.evidence'), "\n");
    }

    return ($root, $suite);
}

sub run_scheduler_with_mock_runner {
    my (%args) = @_;

    my $root = tempdir(CLEANUP => 1);
    my $suite = File::Spec->catdir($root, 'suite');
    my $plan = File::Spec->catfile($root, 'plan.csv');
    write_plan($plan, @{ $args{modules} });

    my $worker_log = File::Spec->catfile($root, 'worker.log');
    my $fork_log   = File::Spec->catfile($root, 'fork.log');
    my $reap_log   = File::Spec->catfile($root, 'reap.log');

    {
        no warnings 'redefine';
        local *Smoker::Runner::run_one = sub {
            my ($self, %run_args) = @_;
            my $assigned = $run_args{assigned_run_dir} // '';
            append_line(
                $worker_log,
                join "\t",
                    $$,
                    $run_args{run_id} // '',
                    $run_args{module} // '',
                    $assigned,
                    (-d $assigned ? 'reserved' : 'missing'),
            );
            select undef, undef, undef, 0.20
                if $args{linger};
            return $run_args{module} =~ /Fail/ ? 2 : 0;
        };

        local $Smoker::Scheduler::TEST_AFTER_FORK = sub {
            my (%hook) = @_;
            my $child = $hook{children}->{ $hook{pid} };
            append_line(
                $fork_log,
                join "\t",
                    $hook{pid},
                    $child->{seq} // '',
                    $child->{module} // '',
                    $child->{run_dir} // '',
                    (-d ($child->{run_dir} // '') ? 'reserved' : 'missing'),
            );
        };

        local $Smoker::Scheduler::TEST_AFTER_REAP = sub {
            my (%hook) = @_;
            append_line(
                $reap_log,
                join "\t",
                    $hook{pid},
                    exists($hook{children}->{ $hook{pid} }) ? 'still_mapped' : 'removed',
            );
        };

        Smoker::Scheduler::run_plan_csv(
            smoker_root => '.',
            plan        => $plan,
            suite_root  => $suite,
            jobs        => $args{jobs} // 2,
        );
    }

    return {
        root       => $root,
        suite      => $suite,
        worker_log => $worker_log,
        fork_log   => $fork_log,
        reap_log   => $reap_log,
    };
}

{
    my $run = run_scheduler_with_mock_runner(
        modules => [qw(Alpha::One Beta::Two)],
        jobs    => 2,
        linger  => 1,
    );

    my @worker = read_lines($run->{worker_log});
    my @fork   = read_lines($run->{fork_log});
    my @reap   = read_lines($run->{reap_log});

    is(scalar(@worker), 2, 'two workers ran');
    is(scalar(@fork), 2, 'parent observed two fork mappings');
    is(scalar(@reap), 2, 'parent observed two reap mappings');

    my @worker_dirs = map { (split /\t/)[3] } @worker;
    my @worker_states = map { (split /\t/)[4] } @worker;
    is_deeply(\@worker_states, ['reserved', 'reserved'],
        'parent reserves run directories before Runner begins');

    my @fork_dirs = map { (split /\t/)[3] } @fork;
    is_deeply([sort @worker_dirs], [sort @fork_dirs],
        'worker receives the exact paths recorded by the parent');

    my %dir_seen;
    $dir_seen{$_}++ for @worker_dirs;
    is(scalar(keys %dir_seen), 2, 'two dispatched rows receive different directories');
    my $duplicate_assignment = grep { $_ > 1 } values %dir_seen;
    is($duplicate_assignment, 0,
        'concurrent dispatch does not assign the same directory twice');

    is_deeply([immediate_run_dirs($run->{suite})], [qw(000001 000002)],
        'established run-directory naming convention remains unchanged');

    for my $line (@fork) {
        my ($pid, $seq, $module, $run_dir, $state) = split /\t/, $line;
        ok($pid && $seq && $module && $run_dir && $state eq 'reserved',
            'parent PID map contains PID, plan row data, and reserved run directory');
    }

    ok(!grep { /\tstill_mapped\z/ } @reap,
        'mapping is removed at the established safe point after reap processing');
}

{
    my $root = tempdir(CLEANUP => 1);
    my $suite = File::Spec->catdir($root, 'suite');
    my $runs = File::Spec->catdir($suite, 'runs', '000001');
    make_path($runs);
    open my $fh, '>', File::Spec->catfile($runs, 'existing.txt') or die $!;
    print {$fh} "occupied\n";
    close $fh;

    my $plan = File::Spec->catfile($root, 'plan.csv');
    write_plan($plan, 'Occupied::Run');

    my $called = 0;
    my $error = '';
    {
        no warnings 'redefine';
        local *Smoker::Runner::run_one = sub { $called++; return 0 };
        eval {
            Smoker::Scheduler::run_plan_csv(
                smoker_root => '.',
                plan        => $plan,
                suite_root  => $suite,
                jobs        => 1,
            );
            1;
        } or do {
            $error = $@ || 'unknown error';
        };
    }

    like($error, qr/run directory.*exists|nonempty|reserve/i,
        'pre-existing nonempty run directory is not reused');
    is($called, 0, 'worker is not started when parent reservation fails');
}

{
    my $root = tempdir(CLEANUP => 1);
    my $suite = File::Spec->catdir($root, 'suite');
    my $plan = File::Spec->catfile($root, 'plan.csv');
    my $docker_ready = File::Spec->catfile($root, 'docker-ready');
    write_plan($plan, 'Interrupt::DockerRunner');

    my $error = '';
    {
        no warnings 'redefine';
        local *Smoker::Docker::build_docker_cmd = sub {
            return (
                $^X, '-e',
                'select undef,undef,undef,0.3; open my $fh, q{>}, $ARGV[0] or die $!; print {$fh} qq{ready\\n}; close $fh; select undef,undef,undef,30',
                $docker_ready,
            );
        };
        local *Smoker::Docker::_remove_container = sub { return };
        local $Smoker::Scheduler::TEST_AFTER_FORK = sub {
            select undef, undef, undef, 0.01 until -f $docker_ready;
            kill 'TERM', $$;
        };

        eval {
            Smoker::Scheduler::run_plan_csv(
                smoker_root => '.', plan => $plan,
                suite_root => $suite, jobs => 1,
            );
            1;
        } or do {
            $error = $@ || 'unknown error';
        };
    }

    like($error, qr/scheduler interrupted by SIGTERM/,
        'real Runner/Docker interruption path is surfaced');
    my $run_dir = File::Spec->catdir($suite, 'runs', '000001');
    my $meta = read_meta($run_dir);
    is($meta->{rc}, '125',
        'scheduler interruption replaces Docker-caught FAIL/143 with framework rc=125');
    is($meta->{subtype}, 'framework_error',
        'Docker-caught scheduler interruption is recorded as framework_error');
    like(read_text(File::Spec->catfile($run_dir, 'run.out')) // '',
        qr/\[host\] interrupted by SIGTERM/,
        'real Docker run_logged records the caught scheduler signal');
    like(read_text(File::Spec->catfile($run_dir, 'framework_error.evidence')) // '',
        qr/scheduler interrupted/i,
        'Docker-caught scheduler interruption retains explicit framework evidence');
}

{
    my $outdir = tempdir(CLEANUP => 1);
    my $runner = SchedulerReservationTestRunner->new(
        smoker_root => '.',
        batch       => 'invalid_assigned',
        outdir      => $outdir,
    );

    my $outside = File::Spec->catdir($outdir, '..', 'outside-run');
    make_path($outside);

    my $error = '';
    eval {
        $runner->run_one(
            run_id           => 1,
            module           => 'Invalid::Assigned',
            version          => '1.0',
            assigned_run_dir => $outside,
        );
        1;
    } or do {
        $error = $@ || 'unknown error';
    };

    like($error, qr/assigned.*run.*dir|beneath|reserved/i,
        'invalid assigned path is rejected');
}

{
    my $outdir = tempdir(CLEANUP => 1);
    my $runner = SchedulerReservationTestRunner->new(
        smoker_root => '.',
        batch       => 'unreserved_assigned',
        outdir      => $outdir,
    );

    my $unreserved = File::Spec->catdir($outdir, 'runs', '000001');
    my $error = '';
    eval {
        $runner->run_one(
            run_id           => 1,
            module           => 'Unreserved::Assigned',
            version          => '1.0',
            assigned_run_dir => $unreserved,
        );
        1;
    } or do {
        $error = $@ || 'unknown error';
    };

    like($error, qr/assigned.*run.*dir|reserved/i,
        'unreserved assigned path is rejected');
}

{
    my $outdir = tempdir(CLEANUP => 1);
    my $runner = SchedulerReservationTestRunner->new(
        smoker_root => '.',
        batch       => 'direct_runner',
        outdir      => $outdir,
    );

    my $rc = $runner->run_one(
        run_id  => 1,
        module  => 'Direct::Runner',
        version => '1.0',
    );

    is($rc, 0, 'direct Runner invocation remains supported');
    ok(-d File::Spec->catdir($outdir, 'runs', '000001'),
        'direct Runner invocation allocates its established run directory');
}

for my $case (
    [ pass        => 0,   'PASS',        '' ],
    [ module_fail => 2,   'FAIL',        '' ],
    [ unavailable => 111, 'UNAVAILABLE', '' ],
) {
    my ($name, $attempt_rc, $status, $subtype) = @$case;
    my $outdir = tempdir(CLEANUP => 1);
    my $runner = SchedulerReservationTestRunner->new(
        smoker_root => '.',
        batch       => "direct_$name",
        outdir      => $outdir,
    );
    $runner->{test_rc} = $attempt_rc;
    my $rc = $runner->run_one(run_id => 1, module => "Direct::$name", version => '1.0');
    my $rows = summary_rows($outdir);
    is($rc, $attempt_rc, "$name result rc remains unchanged");
    is($rows->[0]{status}, $status, "$name result status remains unchanged");
}

{
    my $outdir = tempdir(CLEANUP => 1);
    my $runner = SchedulerReservationTestRunner->new(
        smoker_root => '.',
        batch       => 'direct_framework_exception',
        outdir      => $outdir,
    );

    {
        no warnings 'redefine';
        local *SchedulerReservationTestRunner::_run_docker_attempt = sub {
            my ($self, %args) = @_;
            open my $cmd, '>', $args{cmd_file} or die $!;
            print {$cmd} "fake docker command\n";
            close $cmd or die $!;
            open my $out, '>', $args{run_out} or die $!;
            print {$out} "fake execution before framework failure\n";
            close $out or die $!;
            die "caught Runner framework failure\n";
        };
        my $rc = $runner->run_one(run_id => 1, module => 'Direct::Framework', version => '1.0');
        my $rows = summary_rows($outdir);
        is($rc, 125, 'caught Runner framework failure remains rc=125');
        is($rows->[0]{status}, 'FAIL', 'caught Runner framework failure remains FAIL');
    }
}

{
    my $root = tempdir(CLEANUP => 1);
    my $suite = File::Spec->catdir($root, 'suite');
    my $plan = File::Spec->catfile($root, 'plan.csv');
    write_plan($plan, 'Abrupt::Death');

    {
        no warnings 'redefine';
        local *Smoker::Runner::run_one = sub {
            my ($self, %args) = @_;
            _exit(9);
        };

        Smoker::Scheduler::run_plan_csv(
            smoker_root => '.',
            plan        => $plan,
            suite_root  => $suite,
            jobs        => 1,
        );
    }

    ok(-d File::Spec->catdir($suite, 'runs', '000001'),
        'abrupt worker death leaves the parent-reserved run directory');
    is(read_text(File::Spec->catfile($suite, 'runs', '000001', 'rc.code')),
        "125\n",
        'parent recovers abrupt worker death as rc=125');
    is(scalar(@{ summary_rows($suite) }), 1,
        'parent writes exactly one recovery summary row for abrupt worker death');
}

for my $case (
    [ missing_rc                => 'worker exit without rc.code' ],
    [ malformed_rc              => 'worker exit with malformed rc.code' ],
    [ missing_meta              => 'worker exit without result.meta' ],
    [ bad_meta                  => 'worker exit with malformed result.meta' ],
    [ missing_summary           => 'worker exit without summary row' ],
    [ duplicate_summary         => 'worker exit with duplicate summary rows' ],
    [ summary_status_mismatch   => 'summary status inconsistent with artifacts' ],
    [ summary_rc_mismatch       => 'summary rc inconsistent with rc.code' ],
    [ missing_framework_reason  => 'framework result missing reason' ],
    [ missing_framework_evidence => 'framework result missing evidence' ],
    [ partial_normal            => 'worker exits after partial normal finalization' ],
    [ outside_runner_exception  => 'child exception outside Runner boundary' ],
    [ signal                    => 'child killed by signal' ],
) {
    my ($fault, $label) = @$case;
    my $run = run_scheduler_recovery_case(fault => $fault, module => "Recover::$fault");
    assert_recovered_framework_result($run, $label);
    if ($fault eq 'signal') {
        like($run->{evidence}, qr/signal/i,
            'available terminating signal evidence is retained');
    }
}

{
    my $run = run_scheduler_recovery_case(fault => 'outside_runner_exception');
    assert_recovered_framework_result($run, 'repeated recovery first pass');

    Smoker::Scheduler::recover_child_result(
        child => {
            seq     => 1,
            module  => 'Recover::outside_runner_exception',
            version => '1.0',
            mode    => 'baseline',
            base    => 'perl:5.38',
            run_dir => $run->{run_dir},
            row     => {
                base => 'perl:5.38', mode => 'baseline',
                module => 'Recover::outside_runner_exception', version => '1.0',
                dep_one => '', dep_one_version => '',
                dep_two => '', dep_two_version => '',
            },
            dispatched_at => time(),
        },
        suite_root => $run->{suite},
        batch      => 'suite',
        reason     => 'repeat recovery attempt',
    );
    my $rows = summary_rows($run->{suite});
    is(scalar(@$rows), 1, 'repeated recovery does not append a duplicate summary row');
    is($rows->[0]{rc}, '125', 'repeated recovery preserves framework rc');
}

for my $case (
    [ complete_pass        => 'complete PASS remains PASS',        'PASS',        '0' ],
    [ complete_fail        => 'complete module FAIL remains FAIL', 'FAIL',        '2' ],
    [ complete_unavailable => 'complete UNAVAILABLE remains rc=111', 'UNAVAILABLE', '111' ],
    [ complete_framework   => 'complete framework failure remains unchanged', 'FAIL', '125' ],
) {
    my ($fault, $label, $status, $rc) = @$case;
    my $run = run_scheduler_recovery_case(fault => $fault, module => "Preserve::$fault");
    is(scalar(@{ $run->{rows} }), 1, "$label: one summary row");
    is($run->{rows}[0]{status}, $status, "$label: status");
    is($run->{rows}[0]{rc}, $rc, "$label: rc");
    is($run->{rc_text}, "$rc\n", "$label: rc.code");
}

{
    my $root = tempdir(CLEANUP => 1);
    my $suite = File::Spec->catdir($root, 'suite');
    my $plan = File::Spec->catfile($root, 'plan.csv');
    write_plan($plan, 'Fork::Failure');

    my $error = '';
    {
        no warnings 'redefine';
        local $Smoker::Scheduler::TEST_FORK = sub { return undef };
        eval {
            Smoker::Scheduler::run_plan_csv(
                smoker_root => '.',
                plan        => $plan,
                suite_root  => $suite,
                jobs        => 1,
            );
            1;
        } or do {
            $error = $@ || 'unknown error';
        };
    }

    like($error, qr/fork failed/i, 'fork failure is surfaced');
    my $run_dir = File::Spec->catdir($suite, 'runs', '000001');
    my $rows = summary_rows($suite);
    is(read_text(File::Spec->catfile($run_dir, 'rc.code')), "125\n",
        'fork failure after reservation is recovered as rc=125');
    is(scalar(@$rows), 1, 'fork failure writes exactly one summary row');
    like(
        read_text(File::Spec->catfile($run_dir, 'framework_error.evidence')) // '',
        qr/no worker PID|no wait status/i,
        'fork failure records no invented PID or wait status',
    );
}

{
    my $run = run_scheduler_with_mock_runner(
        modules => [qw(Multi::Good Multi::Crash)],
        jobs    => 2,
    );
    ok(-f File::Spec->catfile($run->{suite}, 'summary.csv'),
        'multiple workers complete with a readable summary.csv');
}

{
    my ($root, $suite) = make_validator_recovery_fixture();
    my $report = File::Spec->catfile($root, 'validation-pass.txt');
    my $raw = system($^X, 'bin/validate_smoker_batch.pl', $suite, $report);
    is($raw >> 8, 0, 'validator accepts disposable recovered framework fixture');
    like(read_text($report), qr/Assessment: PASS/,
        'validator classifies recovered fixture as complete and evidenced');
}

{
    my ($root, $suite) = make_validator_recovery_fixture(corrupt => 1);
    my $report = File::Spec->catfile($root, 'validation-fail.txt');
    my $raw = system($^X, 'bin/validate_smoker_batch.pl', $suite, $report);
    isnt($raw >> 8, 0, 'validator rejects corrupted recovered framework fixture');
    like(read_text($report), qr/Assessment: FAIL/,
        'validator reports corrupted recovered fixture as failing');
}

{
    my $decoded = decode_wait_status(9 | 128);
    is($decoded->{signal}, 9, 'constructed wait status decodes terminating signal');
    is($decoded->{core_dumped}, 1,
        'constructed wait status decodes portable core-dump indication');
}

{
    my $root = tempdir(CLEANUP => 1);
    my $suite = File::Spec->catdir($root, 'suite');
    my $plan = File::Spec->catfile($root, 'plan.csv');
    write_plan($plan, qw(Interrupt::Active Interrupt::PendingOne Interrupt::PendingTwo));

    my $error = '';
    {
        no warnings 'redefine';
        local *Smoker::Runner::run_one = sub {
            select undef, undef, undef, 10;
            return 0;
        };
        local $Smoker::Scheduler::TEST_AFTER_FORK = sub {
            kill 'TERM', $$;
        };

        eval {
            Smoker::Scheduler::run_plan_csv(
                smoker_root => '.', plan => $plan,
                suite_root => $suite, jobs => 1,
            );
            1;
        } or do {
            $error = $@ || 'unknown error';
        };
    }

    like($error, qr/scheduler interrupted by SIGTERM/,
        'scheduler interruption is surfaced after recovery');
    is_deeply([immediate_run_dirs($suite)], [qw(000001 000002 000003)],
        'scheduler interruption reserves one run directory for every unique row');
    my $rows = summary_rows($suite);
    is(scalar(@$rows), 3,
        'scheduler interruption writes one summary row for every unique row');
    is_deeply([map { $_->{rc} } @$rows], [qw(125 125 125)],
        'active and undispatched rows become evidenced framework failures');
    for my $run_id (qw(000001 000002 000003)) {
        my $run_dir = File::Spec->catdir($suite, 'runs', $run_id);
        is(read_text(File::Spec->catfile($run_dir, 'rc.code')), "125\n",
            "$run_id has framework rc.code after scheduler interruption");
        like(read_text(File::Spec->catfile($run_dir, 'framework_error.evidence')) // '',
            qr/scheduler interrupted/i,
            "$run_id retains explicit scheduler-interruption evidence");
    }
}

{
    my $root = tempdir(CLEANUP => 1);
    my $suite = File::Spec->catdir($root, 'suite');
    my $run_dir = File::Spec->catdir($suite, 'runs', '000001');
    make_path($run_dir);
    make_path(File::Spec->catfile($suite, 'summary.csv'));

    my $error = '';
    eval {
        Smoker::Scheduler::recover_child_result(
            child => {
                seq => 1,
                module => 'Recovery::Failure',
                version => '1.0',
                mode => 'baseline',
                base => 'perl:5.38',
                run_dir => $run_dir,
                suite_root => $suite,
                batch => 'suite',
                row => {
                    base => 'perl:5.38', mode => 'baseline',
                    module => 'Recovery::Failure', version => '1.0',
                    dep_one => '', dep_one_version => '',
                    dep_two => '', dep_two_version => '',
                },
                dispatched_at => time(),
            },
            reason => 'summary path is blocked',
            stage => 'recovery_failure_test',
        );
        1;
    } or do {
        $error = $@ || 'unknown error';
    };

    like($error, qr/open .*summary\.csv|unexpected summary header|Is a directory|directory/i,
        'recovery failure is surfaced when summary path cannot be written');
}

done_testing;
