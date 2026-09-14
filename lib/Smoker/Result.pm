package Smoker::Result;

use strict;
use warnings;

use Exporter 'import';
use Fcntl qw(:flock);
use File::Path qw(make_path);
use File::Spec;
use POSIX qw(strftime);
use Text::CSV;

our @EXPORT_OK = qw(
    atomic_write_text
    classify_result
    decode_wait_status
    finalize_result
    inspect_result
    single_line_reason
    summary_header_fields
    iso8601_utc
);

our $TEST_BEFORE_SUMMARY_RENAME;
our $TEST_AFTER_SUMMARY_APPEND;
our $TEST_AFTER_SUMMARY_RENAME;
our $TEST_BEFORE_ATOMIC_RENAME;

sub atomic_write_text {
    return _atomic_write(@_);
}

sub classify_result {
    my (%args) = @_;

    my $rc = $args{rc};
    $rc = 125 unless defined $rc && $rc =~ /\A-?\d+\z/;
    $rc = 0 + $rc;

    # A code determines the top-level status, but only explicit state from the
    # originating layer may assign a causal subtype or normalize that cause.
    $rc = 8 if $rc == 124 && $args{timed_out};

    $rc = 125 if $args{framework_error};

    if ($rc == 4 && $args{confirmed_unavailable}) {
        $rc = 111;
    }

    my $status = $rc == 0   ? 'PASS'
               : $rc == 111 ? 'UNAVAILABLE'
               :              'FAIL';

    my $subtype = $args{timed_out}             ? 'timeout'
                : $args{log_limit_exceeded}    ? 'log_limit_exceeded'
                : ($args{framework_error} || $rc == 125) ? 'framework_error'
                :              '';

    my $note = $args{timed_out}
        ? 'Execution timed out'
        : $args{log_limit_exceeded}
            ? 'Execution aborted because the build log exceeded the safety limit'
            : '';

    return {
        rc      => $rc,
        status  => $status,
        subtype => $subtype,
        note    => $note,
    };
}

sub decode_wait_status {
    my ($status) = @_;
    return {
        raw_wait_status => '',
        exit_code       => '',
        signal          => '',
        core_dumped     => '',
    } unless defined $status && $status =~ /\A-?\d+\z/;

    return {
        raw_wait_status => 0 + $status,
        exit_code       => ($status >> 8),
        signal          => ($status & 127),
        core_dumped     => (($status & 128) ? 1 : 0),
    };
}

sub summary_header_fields {
    return qw(
        run_id batch base mode module version
        dep_one dep_one_version dep_two dep_two_version
        status rc start_ts end_ts elapsed_s run_dir note
    );
}

sub finalize_result {
    my (%args) = @_;

    my $run_dir = $args{run_dir};
    die "finalize_result missing run_dir\n"
        unless defined $run_dir && $run_dir ne '';
    die "finalize_result run_dir is not a directory: $run_dir\n"
        unless -d $run_dir;

    my $rc = defined $args{rc} ? "$args{rc}" : '';
    my $subtype = $args{subtype} // '';
    if ($rc eq '125' && $subtype ne 'framework_error') {
        die "finalize_result rc=125 requires subtype=framework_error\n";
    }
    if ($subtype eq 'framework_error' && $rc ne '125') {
        die "finalize_result subtype=framework_error requires rc=125\n";
    }
    if ($subtype eq 'framework_error'
        && (!defined($args{framework_reason}) || $args{framework_reason} !~ /\S/)) {
        die "finalize_result framework_error requires a nonempty framework reason\n";
    }

    my $summary_file = $args{summary_file}
        // File::Spec->catfile($args{outdir} // '.', 'summary.csv');
    my $rc_file = $args{rc_file} // File::Spec->catfile($run_dir, 'rc.code');
    my $meta_file = $args{meta_file} // File::Spec->catfile($run_dir, 'result.meta');
    my $audit_file = $args{audit_file} // File::Spec->catfile($run_dir, 'execution_trail.audit');
    my $cmd_file = $args{cmd_file} // File::Spec->catfile($run_dir, '00_command.txt');

    my $row = _summary_row(%args, run_dir => $run_dir);
    _ensure_summary_file($summary_file);

    if ($subtype eq 'framework_error') {
        if ($args{write_framework_evidence}) {
            $args{write_framework_evidence}->(%args, run_dir => $run_dir);
        }
        else {
            _write_framework_evidence(%args, run_dir => $run_dir);
        }
    }

    if (!-f $cmd_file) {
        _atomic_write($cmd_file, "command unavailable; parent framework recovery\n");
    }

    if ($args{write_rc_file}) {
        $args{write_rc_file}->($rc_file, $args{rc}, $args{framework_recovery});
    }
    else {
        _write_rc_file($rc_file, $args{rc});
    }

    if ($args{write_result_meta}) {
        $args{write_result_meta}->(%args, meta_file => $meta_file, run_dir => $run_dir);
    }
    else {
        _write_result_meta(%args, meta_file => $meta_file, run_dir => $run_dir);
    }

    my @audit_args = (
        path         => $audit_file,
        run_dir      => $run_dir,
        rc_file      => $rc_file,
        meta_file    => $meta_file,
        cmd_file     => $cmd_file,
        summary_file => $summary_file,
        expected     => {
            run_id  => $args{run_id},
            batch   => $args{batch},
            base    => $args{base},
            mode    => $args{mode},
            module  => $args{module},
            version => $args{version},
            status  => $args{status},
            rc      => "$args{rc}",
        },
    );

    if ($args{write_audit}) {
        $args{write_audit}->(@audit_args);
    }
    else {
        _write_execution_trail_audit(@audit_args);
    }

    _update_or_insert_summary_row(
        $summary_file,
        $row,
        reconcile => ($args{framework_recovery} ? 1 : 0),
    );

    return $args{rc};
}

sub inspect_result {
    my (%args) = @_;

    my $run_dir = $args{run_dir};
    my $summary_file = $args{summary_file}
        // File::Spec->catfile($args{outdir} // '.', 'summary.csv');
    my $run_id = $args{run_id};
    my @issues;

    push @issues, 'run directory missing'
        unless defined $run_dir && -d $run_dir;
    return { complete => 0, issues => \@issues }
        if @issues;

    my $rc_file = File::Spec->catfile($run_dir, 'rc.code');
    my $meta_file = File::Spec->catfile($run_dir, 'result.meta');
    my $audit_file = File::Spec->catfile($run_dir, 'execution_trail.audit');

    my $rc_text = _read_text($rc_file);
    push @issues, 'missing rc.code' unless defined $rc_text;
    my $rc = '';
    if (defined $rc_text) {
        $rc_text =~ s/^\s+|\s+$//g;
        if ($rc_text =~ /\A-?\d+\z/) {
            $rc = $rc_text;
        }
        else {
            push @issues, 'malformed rc.code';
        }
    }

    my $meta = _read_meta($meta_file);
    push @issues, 'missing result.meta' unless $meta;
    if ($meta) {
        for my $key (qw(status rc run_id batch base mode module version run_dir)) {
            push @issues, "result.meta missing $key"
                unless exists $meta->{$key} && defined $meta->{$key};
        }
        push @issues, 'result.meta rc disagrees with rc.code'
            if length($rc) && defined($meta->{rc}) && $meta->{rc} ne $rc;
    }

    my $summary = _summary_rows_for_run($summary_file, $run_id);
    push @issues, 'missing summary row' if @$summary == 0;
    push @issues, 'duplicate summary rows' if @$summary > 1;
    if (@$summary == 1) {
        my $row = $summary->[0];
        push @issues, 'summary rc disagrees with rc.code'
            if length($rc) && ($row->{rc} // '') ne $rc;
        push @issues, 'summary status disagrees with result.meta'
            if $meta && ($row->{status} // '') ne ($meta->{status} // '');
        push @issues, 'summary rc disagrees with result.meta'
            if $meta && ($row->{rc} // '') ne ($meta->{rc} // '');
        push @issues, 'summary run_dir disagrees with assigned run_dir'
            if ($row->{run_dir} // '') ne $run_dir;
    }

    my $audit = _read_text($audit_file);
    push @issues, 'missing execution_trail.audit'
        unless defined $audit && $audit =~ /\S/;

    my $status = $meta ? ($meta->{status} // '') : '';
    if (length $rc) {
        my $expected = classify_result(rc => $rc)->{status};
        push @issues, 'status/rc inconsistency'
            if $status ne '' && $status ne $expected;
    }

    my $subtype = $meta ? ($meta->{subtype} // '') : '';
    if (length($rc) && $rc eq '125') {
        push @issues, 'rc=125 missing framework subtype'
            unless $subtype eq 'framework_error';
    }
    if ($subtype eq 'framework_error') {
        push @issues, 'framework subtype without rc=125'
            unless length($rc) && $rc eq '125';
        my $evidence =
            (_read_text(File::Spec->catfile($run_dir, 'framework_error.evidence')) // '')
            . "\n"
            . (_read_text(File::Spec->catfile($run_dir, 'framework_error.note')) // '');
        push @issues, 'missing framework evidence'
            unless $evidence =~ /framework|exception|worker.*(?:exit|signal)|signal/i;
        push @issues, 'missing framework reason'
            unless ($meta->{note} // '') =~ /\S/;
    }

    return {
        complete => @issues ? 0 : 1,
        issues   => \@issues,
        status   => $status,
        rc       => $rc,
        subtype  => $subtype,
        interrupted => $meta ? ($meta->{interrupted} // '') : '',
        interrupt_signal => $meta ? ($meta->{interrupt_signal} // '') : '',
    };
}

sub iso8601_utc {
    my ($epoch) = @_;
    $epoch = time() unless defined $epoch;
    return strftime("%Y-%m-%dT%H:%M:%SZ", gmtime($epoch));
}

sub single_line_reason {
    my ($value, $fallback) = @_;
    $fallback = 'unknown framework error' unless defined $fallback && $fallback ne '';
    $value = $fallback unless defined $value && $value ne '';
    $value =~ s/[\r\n]+/ /g;
    $value =~ s/\0//g;
    $value =~ s/^\s+|\s+$//g;
    return length($value) ? $value : $fallback;
}

sub _summary_row {
    my (%args) = @_;
    return {
        run_id          => $args{run_id},
        batch           => $args{batch},
        base            => $args{base},
        mode            => $args{mode},
        module          => $args{module},
        version         => $args{version},
        dep_one         => $args{dep_one} // '',
        dep_one_version => $args{dep_one_version} // '',
        dep_two         => $args{dep_two} // '',
        dep_two_version => $args{dep_two_version} // '',
        status          => $args{status},
        rc              => $args{rc},
        start_ts        => $args{start_ts},
        end_ts          => $args{end_ts},
        elapsed_s       => $args{elapsed_s},
        run_dir         => $args{run_dir},
        note            => $args{note},
    };
}

sub _write_rc_file {
    my ($path, $rc) = @_;
    _atomic_write($path, "$rc\n");
}

sub _write_result_meta {
    my (%args) = @_;
    my @meta_pairs = (
        [run_id          => $args{run_id}],
        [batch           => $args{batch}],
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
    _atomic_write(
        $args{meta_file},
        join("\n", map { $_->[0] . '=' . _meta_value($_->[1]) } @meta_pairs) . "\n",
    );
}

sub _write_framework_evidence {
    my (%args) = @_;

    my @lines = (
        "framework_error=1",
        "reason=" . single_line_reason($args{framework_reason} || 'framework error result'),
        "stage=" . single_line_reason($args{stage} || '', 'scheduler_recovery'),
        "worker_pid=" . _meta_value($args{worker_pid}),
        "raw_return_code=" . _meta_value($args{raw_return_code}),
        "raw_wait_status=" . _meta_value($args{raw_wait_status}),
        "interrupted=" . ($args{interrupted} ? 1 : 0),
        "interrupt_signal=" . _meta_value($args{interrupt_signal}),
        "core_dumped=" . _meta_value($args{core_dumped}),
        "run_dir=" . _meta_value($args{run_dir}),
        "run_id=" . _meta_value($args{run_id}),
    );

    if (!defined($args{worker_pid}) || $args{worker_pid} eq '') {
        push @lines, "worker_pid_unavailable=no worker PID existed";
    }
    if (!defined($args{raw_wait_status}) || $args{raw_wait_status} eq '') {
        push @lines, "wait_status_unavailable=no wait status existed";
    }

    _atomic_write(
        File::Spec->catfile($args{run_dir}, 'framework_error.evidence'),
        join("\n", @lines) . "\n",
    );
}

sub _write_execution_trail_audit {
    my (%args) = @_;

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

    _atomic_write(
        $args{path},
        join("\n",
            "record=framework_execution_trail",
            "scope=factual_producer_execution_record",
            "recorded_at=" . iso8601_utc(time()),
            "run_id=" . _meta_value($args{expected}{run_id}),
            "run_dir=" . _meta_value($args{run_dir}),
            "rc_file=" . _meta_value($args{rc_file}),
            "result_meta=" . _meta_value($args{meta_file}),
            "command_file=" . _meta_value($args{cmd_file}),
            "summary_file=" . _meta_value($args{summary_file}),
            "observed_issue_count=" . scalar(@issues),
            map({ "observed_issue_" . ($_ + 1) . "=$issues[$_]" } 0 .. $#issues),
        ) . "\n",
    );

    die "execution-trail audit failed for $args{run_dir}: " . join('; ', @issues) . "\n"
        if @issues;
}

sub _ensure_summary_file {
    my ($path) = @_;
    my $wanted = join(',', summary_header_fields()) . "\n";

    my $lock = _lock_summary($path);

    if (!-e $path) {
        _atomic_write($path, $wanted);
    }
    else {
        open my $fh, '<', $path or die "open $path: $!";
        my $header = <$fh>;
        close $fh or die "close $path: $!";
        die "unexpected summary header in $path\n"
            unless defined $header && $header eq $wanted;
    }

    _unlock_summary($lock, $path);
}

sub _update_or_insert_summary_row {
    my ($path, $wanted_row, %args) = @_;
    my @fields = summary_header_fields();
    my $csv = Text::CSV->new({ binary => 1, eol => "\n" });

    my $lock = _lock_summary($path);
    my $index_dir = _ensure_summary_index($path, \@fields);
    my $index_entry = File::Spec->catfile(
        $index_dir,
        unpack('H*', $wanted_row->{run_id} // ''),
    );
    my $state_path = File::Spec->catfile(
        $wanted_row->{run_dir},
        '.summary-row.state',
    );
    my $state = _read_text($state_path) // '';
    $state =~ s/\s+\z//;

    if ($state eq '' && !$args{reconcile} && !-f $index_entry) {
        _atomic_write($state_path, "pending\n");
        open my $append, '>>', $path or die "append $path: $!";
        $csv->print($append, [ @{$wanted_row}{@fields} ])
            or die "append summary row to $path\n";
        close $append or die "close $path: $!";
        $TEST_AFTER_SUMMARY_APPEND->($path, $wanted_row)
            if $TEST_AFTER_SUMMARY_APPEND;
        _atomic_write($index_entry, "indexed\n");
        _atomic_write($state_path, "committed\n");
        _unlock_summary($lock, $path);
        return;
    }

    _atomic_write($state_path, "pending\n") if $state eq '';

    open my $fh, '<', $path or die "open $path: $!";

    my $header = $csv->getline($fh);
    die "missing summary header in $path\n" unless $header;
    die "unexpected summary header in $path\n"
        unless join("\0", @$header) eq join("\0", @fields);
    $csv->column_names(@$header);

    my @rows;
    while (my $row = $csv->getline_hr($fh)) {
        push @rows, $row;
    }
    close $fh or die "close $path: $!";

    my @new_rows;
    my $replaced = 0;
    for my $row (@rows) {
        if (($row->{run_id} // '') eq ($wanted_row->{run_id} // '')) {
            if (!$replaced) {
                push @new_rows, { %$wanted_row };
                $replaced = 1;
            }
            next;
        }
        push @new_rows, $row;
    }
    push @new_rows, { %$wanted_row } unless $replaced;

    my ($volume, $dir, $file) = File::Spec->splitpath($path);
    my $tmp = File::Spec->catpath(
        $volume,
        $dir,
        ".$file.$$\." . int(rand(1_000_000)) . '.tmp',
    );
    open my $out, '>', $tmp or die "write $tmp: $!";
    $csv->print($out, \@fields) or die "write summary header to $tmp\n";
    for my $row (@new_rows) {
        $csv->print($out, [ @{$row}{@fields} ])
            or die "write summary row to $tmp\n";
    }
    close $out or die "close $tmp: $!";

    $TEST_BEFORE_SUMMARY_RENAME->($path, $tmp)
        if $TEST_BEFORE_SUMMARY_RENAME;
    rename $tmp, $path or die "rename $tmp to $path: $!";
    $TEST_AFTER_SUMMARY_RENAME->($path, $wanted_row)
        if $TEST_AFTER_SUMMARY_RENAME;
    _atomic_write($index_entry, "indexed\n");
    _atomic_write($state_path, "committed\n");

    _unlock_summary($lock, $path);
}

sub _ensure_summary_index {
    my ($path, $fields) = @_;
    my $index_dir = "$path.run-index";
    make_path($index_dir) unless -d $index_dir;

    my $initialized = File::Spec->catfile($index_dir, '.initialized');
    return $index_dir if -f $initialized;

    my $csv = Text::CSV->new({ binary => 1 });
    open my $fh, '<', $path or die "read $path for summary index: $!";
    my $header = $csv->getline($fh);
    die "missing summary header in $path\n" unless $header;
    die "unexpected summary header in $path\n"
        unless join("\0", @$header) eq join("\0", @$fields);
    $csv->column_names(@$header);

    while (my $row = $csv->getline_hr($fh)) {
        my $run_id = $row->{run_id} // '';
        die "summary row without run_id in $path\n" if $run_id eq '';
        my $entry = File::Spec->catfile($index_dir, unpack('H*', $run_id));
        _atomic_write($entry, "indexed\n") unless -f $entry;
    }
    die "malformed CSV while building summary index for $path: " . $csv->error_diag . "\n"
        unless $csv->eof;
    close $fh or die "close $path: $!";
    _atomic_write($initialized, "summary_run_index_version=1\n");
    return $index_dir;
}

sub _lock_summary {
    my ($path) = @_;
    my $lock_path = "$path.lock";
    open my $lock, '>>', $lock_path or die "open $lock_path: $!";
    flock($lock, LOCK_EX) or die "flock $lock_path: $!";
    return $lock;
}

sub _unlock_summary {
    my ($lock, $path) = @_;
    flock($lock, LOCK_UN) or die "unlock $path.lock: $!";
    close $lock or die "close $path.lock: $!";
}

sub _summary_rows_for_run {
    my ($path, $run_id) = @_;
    return [] unless -f $path;

    my $csv = Text::CSV->new({ binary => 1 });
    open my $fh, '<', $path or die "read $path: $!";
    my $header = $csv->getline($fh);
    return [] unless $header;
    $csv->column_names(@$header);
    my @rows;
    while (my $row = $csv->getline_hr($fh)) {
        push @rows, $row if ($row->{run_id} // '') eq $run_id;
    }
    close $fh;
    return \@rows;
}

sub _read_text {
    my ($path) = @_;
    return undef unless defined $path && -f $path;
    open my $fh, '<', $path or return undef;
    local $/;
    my $text = <$fh>;
    close $fh;
    return $text;
}

sub _read_meta {
    my ($path) = @_;
    my $text = _read_text($path);
    return undef unless defined $text && $text =~ /\S/;
    my %meta;
    for my $line (split /\r?\n/, $text) {
        next unless $line =~ /\A([^=]+)=(.*)\z/;
        $meta{$1} = $2;
    }
    return \%meta;
}

sub _atomic_write {
    my ($path, $text) = @_;
    my ($volume, $dir, $file) = File::Spec->splitpath($path);
    my $tmp = File::Spec->catpath($volume, $dir, ".$file.$$." . int(rand(1_000_000)) . ".tmp");
    open my $fh, '>', $tmp or die "write $tmp: $!";
    print {$fh} $text;
    close $fh or die "close $tmp: $!";
    $TEST_BEFORE_ATOMIC_RENAME->($path, $tmp)
        if $TEST_BEFORE_ATOMIC_RENAME;
    rename $tmp, $path or die "rename $tmp to $path: $!";
}

sub _meta_value {
    my ($value) = @_;
    $value = '' unless defined $value;
    $value =~ s/[\r\n]+/ /g;
    $value =~ s/\0//g;
    return $value;
}

1;
