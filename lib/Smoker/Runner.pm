package Smoker::Runner;

use strict;
use warnings;

use File::Path qw(make_path);
use File::Spec;
use Cwd qw(abs_path);
use Time::HiRes qw(time);
use POSIX qw(strftime);
use Fcntl qw(:flock);

use Smoker::Docker ();
use Smoker::Notes ();
use Smoker::Result qw(
    atomic_write_text
    classify_result
    finalize_result
    iso8601_utc
    single_line_reason
    summary_header_fields
);

sub new {
    my ($class, %args) = @_;

    my $self = bless {
        smoker_root => $args{smoker_root} || $ENV{SMOKER_HOME} || $ENV{SMOKER_ROOT},
        batch       => $args{batch}   || 'smoke_batch',
        outdir      => $args{outdir}  || '.',
        mode        => $args{mode}    || 'baseline',
        base        => $args{base}    || 'perl:5.38',
        timeout     => $args{timeout} || 1800,
    }, $class;

    make_path($self->{outdir}) unless -d $self->{outdir};
    make_path(File::Spec->catdir($self->{outdir}, 'runs'));

    $self->_init_summary_csv;

    return $self;
}

sub run_one {
    my ($self, %args) = @_;

    my $run_id = $args{run_id};
    defined $run_id
        or die "run_one: missing run_id\n";
    $run_id =~ /\A\d+\z/
        or die "run_one: invalid run_id: $run_id\n";

    my $module  = $args{module} // die "run_one: missing module\n";
    my $version = defined $args{version} ? $args{version} : '';

    my $mode    = $args{mode}    || $self->{mode};
    my $base    = $args{base}    || $self->{base};
    my $timeout = $args{timeout} || $self->{timeout};

    my $dep_one         = $args{dep_one}         // '';
    my $dep_one_version = $args{dep_one_version} // '';
    my $dep_two         = $args{dep_two}         // '';
    my $dep_two_version = $args{dep_two_version} // '';

    my @notes = (
        $args{note},
        Smoker::Notes->dependency_version($dep_one, $dep_one_version),
        Smoker::Notes->dependency_version($dep_two, $dep_two_version),
    );

    my $run_dir;
    if (exists $args{assigned_run_dir}) {
        $run_dir = $self->_validate_assigned_run_dir(
            run_id => $run_id,
            path   => $args{assigned_run_dir},
        );
    }
    else {
        $run_dir = $self->_make_run_dir(
            run_id          => $run_id,
            module          => $module,
            version         => $version,
            mode            => $mode,
            base            => $base,
            dep_one         => $dep_one,
            dep_one_version => $dep_one_version,
            dep_two         => $dep_two,
            dep_two_version => $dep_two_version,
        );

        make_path($run_dir);
    }

    my $run_out   = File::Spec->catfile($run_dir, 'run.out');
    my $run_err   = File::Spec->catfile($run_dir, 'run.err');
    my $rc_file   = File::Spec->catfile($run_dir, 'rc.code');
    my $meta_file = File::Spec->catfile($run_dir, 'result.meta');
    my $audit_file = File::Spec->catfile($run_dir, 'execution_trail.audit');
    my $cmd_file  = File::Spec->catfile($run_dir, '00_command.txt');

    my $t0 = time();
    my $start_ts = _iso8601_utc($t0);
    my %ctx = (
        run_id          => sprintf('%06d', $run_id),
        run_dir         => $run_dir,
        run_out         => $run_out,
        run_err         => $run_err,
        rc_file         => $rc_file,
        meta_file       => $meta_file,
        audit_file      => $audit_file,
        cmd_file        => $cmd_file,
        start_ts        => $start_ts,
        t0              => $t0,
        base            => $base,
        mode            => $mode,
        module          => $module,
        version         => $version,
        dep_one         => $dep_one,
        dep_one_version => $dep_one_version,
        dep_two         => $dep_two,
        dep_two_version => $dep_two_version,
        attempt         => {},
        stage           => 'starting',
    );

    my $return_rc;
    my $ok = eval {
        $ctx{stage} = 'docker_attempt';
        my $attempt = $self->_run_docker_attempt(
            run_dir         => $run_dir,
            run_out         => $run_out,
            run_err         => $run_err,
            cmd_file        => $cmd_file,
            base            => $base,
            timeout         => $timeout,
            module          => $module,
            version         => $version,
            mode            => $mode,
            dep_one         => $dep_one,
            dep_one_version => $dep_one_version,
            dep_two         => $dep_two,
            dep_two_version => $dep_two_version,
        );
        $ctx{attempt} = $attempt;
        my $rc = $attempt->{rc};

        # A MiniCPAN mirror contains only the currently indexed release for many
        # distributions.  An exact historical version may therefore be absent
        # locally even though it is still available from live CPAN.  Before
        # recording UNAVAILABLE, verify the result once with the local mirror
        # disabled.  The first attempt is retained as evidence.
        my $mirror_configured = $self->_local_mirror_configured;
        my $retry_trace = File::Spec->catfile($run_dir, 'runner.retry.log');
        $ctx{stage} = 'retry_trace';
        $self->_append_retry_trace(
            $retry_trace,
            "first_attempt_rc=$rc local_mirror_configured="
              . ($mirror_configured ? 'yes' : 'no'),
        );

        my $confirmed_unavailable = 0;

        if (($rc == 4 || $rc == 111) && $mirror_configured) {
            my $local_out = File::Spec->catfile($run_dir, 'run.local_mirror.out');
            my $local_err = File::Spec->catfile($run_dir, 'run.local_mirror.err');
            my $local_cmd = File::Spec->catfile($run_dir, '00_command.local_mirror.txt');

            $ctx{stage} = 'preserve_local_mirror_attempt';
            # run_logged may omit an empty stdout or stderr file.  Preserve each
            # first-attempt artifact that actually exists, but do not abort the
            # worker merely because an empty stream produced no file.
            $self->_move_if_exists($run_out,  $local_out);
            $self->_move_if_exists($run_err,  $local_err);
            $self->_move_if_exists($cmd_file, $local_cmd);
            $self->_move_if_exists(
                File::Spec->catfile($run_dir, 'unavailable.note'),
                File::Spec->catfile($run_dir, 'unavailable.local_mirror.note'),
            );

            $self->_append_retry_trace($retry_trace, 'entering_live_cpan_retry');

            local $ENV{SMOKER_LOCAL_MIRROR};
            delete $ENV{SMOKER_LOCAL_MIRROR};

            $ctx{stage} = 'live_cpan_retry';
            $attempt = $self->_run_docker_attempt(
                run_dir         => $run_dir,
                run_out         => $run_out,
                run_err         => $run_err,
                cmd_file        => $cmd_file,
                base            => $base,
                timeout         => $timeout,
                module          => $module,
                version         => $version,
                mode            => $mode,
                dep_one         => $dep_one,
                dep_one_version => $dep_one_version,
                dep_two         => $dep_two,
                dep_two_version => $dep_two_version,
            );
            $ctx{attempt} = $attempt;
            $rc = $attempt->{rc};

            $self->_append_retry_trace($retry_trace, "live_retry_rc=$rc");

            $confirmed_unavailable = 1
                if $rc == 4 && $self->_nonempty_evidence($run_dir, 'unavailable.note');

            my $verification_note =
                  $rc == 0
                ? 'MiniCPAN missing requested release; found on live CPAN'
                : ($rc == 111 || $confirmed_unavailable)
                ? 'MiniCPAN missing requested release; confirmed unavailable on live CPAN'
                : "MiniCPAN missing requested release; live CPAN retry returned rc=$rc";

            push @notes, $verification_note;
        }

        my $t1 = time();
        my $end_ts = _iso8601_utc($t1);
        my $elapsed = $t1 - $t0;

        my $raw_return_code = $rc;
        $ctx{stage} = 'classification';
        my $result = classify_result(
            rc                    => $rc,
            confirmed_unavailable => $confirmed_unavailable,
            timed_out             => $attempt->{timed_out},
            log_limit_exceeded    => $attempt->{log_limit_exceeded},
            framework_error       => $attempt->{framework_error},
        );
        $rc = $result->{rc};
        my $status  = $result->{status};
        my $subtype = $result->{subtype};
        push @notes, $result->{note};

        push @notes, Smoker::Notes->collect_note_files($run_dir);
        my $note = Smoker::Notes->finalize(@notes);

        $ctx{stage} = 'normal_finalization';
        $return_rc = $self->_finalize_result(
            %ctx,
            status          => $status,
            subtype         => $subtype,
            rc              => $rc,
            end_ts          => $end_ts,
            elapsed_s       => sprintf('%.6f', $elapsed),
            note            => $note,
            raw_return_code => $raw_return_code,
            raw_wait_status => $attempt->{raw_wait_status} // '',
            interrupted     => $attempt->{interrupted} ? 1 : 0,
            interrupt_signal => $attempt->{interrupt_signal} // '',
            framework_reason => '',
        );

        1;
    };

    if (!$ok) {
        my $exception = $@ || 'unknown Runner exception';
        return $self->_finalize_framework_exception(
            %ctx,
            exception => $exception,
            notes     => \@notes,
        );
    }

    return $return_rc;
}

sub _finalize_result {
    my ($self, %args) = @_;

    $self->_prepare_file_slot($args{rc_file});
    $self->_prepare_file_slot($args{meta_file});

    return finalize_result(
        %args,
        batch        => $self->{batch},
        summary_file => $self->_summary_path,
        write_framework_evidence => sub {
            my (%cb_args) = @_;
            $self->_write_framework_evidence(%cb_args);
        },
        write_rc_file => sub {
            my ($path, $rc, $framework_recovery) = @_;
            $self->_write_rc_file($path, $rc, $framework_recovery);
        },
        write_result_meta => sub {
            my (%cb_args) = @_;
            $self->_write_result_meta(%cb_args);
        },
        write_audit => sub {
            my (%cb_args) = @_;
            if ($args{framework_recovery}) {
                Smoker::Runner::_write_execution_trail_audit($self, %cb_args);
            }
            else {
                $self->_write_execution_trail_audit(%cb_args);
            }
        },
    );
}

sub _finalize_framework_exception {
    my ($self, %args) = @_;

    my $reason = _single_line_reason($args{exception});
    my $end = time();
    my $attempt = $args{attempt} || {};
    my @notes = @{ $args{notes} || [] };
    push @notes, "Framework exception at $args{stage}: $reason";
    my $note = Smoker::Notes->finalize(@notes);

    $self->_ensure_summary_file;

    return $self->_finalize_result(
        %args,
        status          => 'FAIL',
        subtype         => 'framework_error',
        rc              => 125,
        end_ts          => _iso8601_utc($end),
        elapsed_s       => sprintf('%.6f', $end - $args{t0}),
        note            => $note,
        framework_reason => $reason,
        raw_return_code => (defined $attempt->{rc} ? $attempt->{rc} : ''),
        raw_wait_status => ($attempt->{raw_wait_status} // ''),
        interrupted     => ($attempt->{interrupted} ? 1 : 0),
        interrupt_signal => ($attempt->{interrupt_signal} // ''),
        framework_recovery => 1,
    );
}

sub _write_rc_file {
    my ($self, $path, $rc) = @_;

    atomic_write_text($path, "$rc\n");
}

sub _write_result_meta {
    my ($self, %args) = @_;

    my @meta_pairs = (
        [run_id          => $args{run_id}],
        [batch           => $self->{batch}],
        [base            => $args{base}],
        [mode            => $args{mode}],
        [module          => $args{module}],
        [version         => $args{version}],
        [dep_one         => $args{dep_one}],
        [dep_one_version => $args{dep_one_version}],
        [dep_two         => $args{dep_two}],
        [dep_two_version => $args{dep_two_version}],
        [status          => $args{status}],
        [subtype         => $args{subtype}],
        [rc              => $args{rc}],
        [start_ts        => $args{start_ts}],
        [end_ts          => $args{end_ts}],
        [elapsed_s       => $args{elapsed_s}],
        [run_dir         => $args{run_dir}],
        [note            => $args{note}],
        [raw_return_code => $args{raw_return_code}],
        [raw_wait_status => $args{raw_wait_status}],
        [interrupted     => $args{interrupted}],
        [interrupt_signal => $args{interrupt_signal}],
    );
    atomic_write_text(
        $args{meta_file},
        join("\n", map { $_->[0] . '=' . _meta_value($_->[1]) } @meta_pairs) . "\n",
    );
}

sub _write_framework_evidence {
    my ($self, %args) = @_;

    my @lines = (
        "framework_error=1",
        "reason=" . _single_line_reason($args{framework_reason} || 'framework error result'),
        "stage=" . _single_line_reason($args{stage} || ''),
        "raw_return_code=" . _meta_value($args{raw_return_code}),
        "raw_wait_status=" . _meta_value($args{raw_wait_status}),
        "interrupted=" . ($args{interrupted} ? 1 : 0),
        "interrupt_signal=" . _meta_value($args{interrupt_signal}),
    );
    my $text = join("\n", @lines) . "\n";

    my $evidence = File::Spec->catfile($args{run_dir}, 'framework_error.evidence');
    die "write $evidence: is a directory\n"
        if !$args{framework_recovery} && -d $evidence;

    if (_try_write_text_file($evidence, $text)) {
        return;
    }

    my $note = File::Spec->catfile($args{run_dir}, 'framework_error.note');
    _try_write_text_file($note, $text)
        or die "write framework-error evidence in $args{run_dir}: $!";
}

sub _ensure_summary_file {
    my ($self) = @_;

    my $path = $self->_summary_path;
    $self->_prepare_file_slot($path) if -d $path;
    $self->_init_summary_csv unless -f $path;
}

sub _prepare_file_slot {
    my ($self, $path) = @_;

    return unless -d $path;
    rmdir $path or die "remove directory blocking file $path: $!";
}

sub _try_write_text_file {
    my ($path, $text) = @_;

    return 0 if -d $path;

    return eval {
        atomic_write_text($path, $text);
        1;
    } ? 1 : 0;
}

sub _write_execution_trail_audit {
    my ($self, %args) = @_;

    my @issues;
    for my $pair (
        [ 'run directory', $args{run_dir}, 1 ],
        [ 'rc.code',       $args{rc_file}, 0 ],
        [ 'result.meta',   $args{meta_file}, 0 ],
        [ '00_command.txt',$args{cmd_file}, 0 ],
        [ 'summary.csv',    $args{summary_file}, 0 ],
    ) {
        my ($label, $path, $is_dir) = @$pair;
        my $ok = $is_dir ? -d $path : -f $path;
        push @issues, "missing $label: $path" unless $ok;
    }

    my $rc_text = '';
    if (open my $fh, '<', $args{rc_file}) {
        local $/;
        $rc_text = <$fh> // '';
        close $fh;
        $rc_text =~ s/\s+\z//;
        push @issues, 'rc.code is not a single integer'
            unless $rc_text =~ /\A-?\d+\z/;
        push @issues, "rc.code mismatch: expected $args{expected}{rc}, found $rc_text"
            if $rc_text ne '' && $rc_text ne $args{expected}{rc};
    }

    my %meta;
    if (open my $fh, '<', $args{meta_file}) {
        while (my $line = <$fh>) {
            chomp $line;
            next unless $line =~ /\A([^=]+)=(.*)\z/;
            $meta{$1} = $2;
        }
        close $fh;
    }
    for my $key (sort keys %{ $args{expected} }) {
        my $got = exists $meta{$key} ? $meta{$key} : '<missing>';
        push @issues, "result.meta $key mismatch: expected $args{expected}{$key}, found $got"
            if $got ne $args{expected}{$key};
    }

    my @audit_lines = (
        "record=framework_execution_trail",
        "scope=factual_producer_execution_record",
        "recorded_at=" . _iso8601_utc(time()),
        "run_id=$args{expected}{run_id}",
        "run_dir=$args{run_dir}",
        "rc_file=$args{rc_file}",
        "result_meta=$args{meta_file}",
        "command_file=$args{cmd_file}",
        "summary_file=$args{summary_file}",
        "observed_issue_count=" . scalar(@issues),
    );
    for my $i (0 .. $#issues) {
        push @audit_lines, "observed_issue_" . ($i + 1) . "=$issues[$i]";
    }
    atomic_write_text($args{path}, join("\n", @audit_lines) . "\n");

    die "execution-trail audit failed for $args{run_dir}: " . join('; ', @issues) . "\n"
        if @issues;
}

sub _move_if_exists {
    my ($self, $from, $to) = @_;

    return 0 unless -e $from;

    unlink $to if -e $to;
    rename $from, $to
        or die "rename $from to $to: $!";

    return 1;
}

sub _append_retry_trace {
    my ($self, $path, $message) = @_;

    open my $fh, '>>', $path
        or die "append $path: $!";
    print {$fh} _iso8601_utc(time()), " ", $message, "\n";
    close $fh or die "close $path: $!";

    return;
}

sub _run_docker_attempt {
    my ($self, %args) = @_;

    my @cmd = Smoker::Docker::build_docker_cmd(
        run_dir         => $args{run_dir},
        base            => $args{base},
        timeout         => $args{timeout},
        smoker_root     => $self->{smoker_root},
        module          => $args{module},
        version         => $args{version},
        mode            => $args{mode},
        dep_one         => $args{dep_one},
        dep_one_version => $args{dep_one_version},
        dep_two         => $args{dep_two},
        dep_two_version => $args{dep_two_version},
    );

    my $cmd_str = Smoker::Docker::docker_cmd_string(@cmd);
    open my $cfh, '>', $args{cmd_file}
        or die "write $args{cmd_file}: $!";
    print {$cfh} $cmd_str;
    close $cfh or die "close $args{cmd_file}: $!";

    my $attempt = Smoker::Docker::run_logged(
        \@cmd,
        $args{run_out},
        $args{run_err},
        $args{timeout},
    );

    ref($attempt) eq 'HASH' && defined $attempt->{rc}
        or die "run_logged returned no structured result\n";

    $attempt->{log_limit_exceeded} = 1
        if $attempt->{rc} == 112
            && $self->_nonempty_evidence($args{run_dir}, 'loglimit.note');

    return $attempt;
}

sub _nonempty_evidence {
    my ($self, $run_dir, $name) = @_;
    my $path = File::Spec->catfile($run_dir, $name);
    return 0 unless -f $path && -s $path;
    open my $fh, '<', $path or return 0;
    local $/;
    my $text = <$fh> // '';
    close $fh;
    return $text =~ /\S/ ? 1 : 0;
}

sub _local_mirror_configured {
    my ($self) = @_;

    my $mirror = $ENV{SMOKER_LOCAL_MIRROR};
    return defined $mirror && $mirror ne '';
}

sub _summary_path {
    my ($self) = @_;
    return File::Spec->catfile($self->{outdir}, 'summary.csv');
}

sub _init_summary_csv {
    my ($self) = @_;

    my $path = $self->_summary_path;

    my $wanted_header = join(",", summary_header_fields());

    # Runner objects may be constructed concurrently after Scheduler forks.
    # Never use a truncating open here: one child could otherwise erase rows
    # already written by another child.
    open my $fh, '+>>', $path or die "open $path: $!";
    flock($fh, LOCK_EX) or die "flock $path: $!";

    seek($fh, 0, 0) or die "seek $path: $!";
    my $header = <$fh>;

    if (!defined $header) {
        seek($fh, 0, 0) or die "seek $path: $!";
        print {$fh} $wanted_header, "\n";
    }
    else {
        chomp $header;
        die "unexpected summary header in $path\n"
            unless $header eq $wanted_header;
    }

    flock($fh, LOCK_UN) or die "unlock $path: $!";
    close $fh or die "close $path: $!";
}

sub _make_run_dir {
    my ($self, %args) = @_;

    my $run_id = $args{run_id};
    defined $run_id
        or die "_make_run_dir: missing run_id\n";
    $run_id =~ /\A\d+\z/
        or die "_make_run_dir: invalid run_id: $run_id\n";

    my $dir_name = sprintf('%06d', $run_id);
    my $run_dir = File::Spec->catdir($self->{outdir}, 'runs', $dir_name);

    -e $run_dir
        and die "run directory already exists: $run_dir\n";

    return $run_dir;
}

sub _validate_assigned_run_dir {
    my ($self, %args) = @_;

    my $run_id = $args{run_id};
    my $path   = $args{path};

    die "assigned run directory is required\n"
        unless defined $path && $path ne '';
    die "assigned run directory requires numeric run_id\n"
        unless defined $run_id && $run_id =~ /\A\d+\z/;

    my $runs_root = File::Spec->catdir($self->{outdir}, 'runs');
    my $expected = File::Spec->catdir($runs_root, sprintf('%06d', $run_id));

    my $assigned_abs = abs_path($path)
        or die "assigned run directory is not reserved or cannot be resolved: $path\n";
    my $expected_abs = abs_path($expected)
        or die "expected assigned run directory is not reserved: $expected\n";
    my $runs_abs = abs_path($runs_root)
        or die "expected runs directory is not reserved: $runs_root\n";

    die "assigned run directory is not beneath expected runs directory: $path\n"
        unless _path_is_beneath($assigned_abs, $runs_abs);

    die "assigned run directory does not match run_id $run_id: $path\n"
        unless $assigned_abs eq $expected_abs;

    die "assigned run directory is not reserved: $path\n"
        unless -d $assigned_abs;

    return $assigned_abs;
}

sub _normalize_rc {
    my ($self, $rc) = @_;
    return classify_result(rc => $rc)->{rc};
}

sub _status_from_rc {
    my ($self, $rc) = @_;
    return classify_result(rc => $rc)->{status};
}

sub _meta_value {
    my ($value) = @_;
    $value = '' unless defined $value;
    $value =~ s/[\r\n]+/ /g;
    $value =~ s/\0//g;
    return $value;
}

sub _single_line_reason {
    my ($value) = @_;

    return single_line_reason($value, 'unknown Runner exception');
}

sub _path_is_beneath {
    my ($path, $parent) = @_;

    my @path_parts   = File::Spec->splitdir(File::Spec->canonpath($path));
    my @parent_parts = File::Spec->splitdir(File::Spec->canonpath($parent));

    return 0 if @path_parts < @parent_parts;

    for my $i (0 .. $#parent_parts) {
        return 0 unless $path_parts[$i] eq $parent_parts[$i];
    }

    return 1;
}

sub _iso8601_utc {
    my ($epoch) = @_;
    return iso8601_utc($epoch);
}

sub _sanitize {
    my ($s) = @_;
    $s = '' unless defined $s;
    $s =~ s/::/_/g;
    $s =~ s/[^A-Za-z0-9._-]+/_/g;
    $s =~ s/^_+//;
    $s =~ s/_+$//;
    $s = 'NA' if $s eq '';
    return $s;
}

1;
