#!/usr/bin/env perl
use strict;
use warnings;

use Cwd qw(abs_path);
use File::Basename qw(basename);
use File::Spec;
use Text::CSV;

sub usage {
    die "usage: " . basename($0) . " BATCH_DIR [OUTPUT_FILE]\n";
}

@ARGV == 1 || @ARGV == 2 or usage();

my $batch = File::Spec->rel2abs($ARGV[0]);
$batch = abs_path($batch) // $batch;

my $output = @ARGV == 2
    ? File::Spec->rel2abs($ARGV[1])
    : File::Spec->catfile($batch, 'result_classification_audit.txt');

my $summary = File::Spec->catfile($batch, 'summary.csv');
-f $summary or die "missing $summary\n";

sub read_meta {
    my ($path) = @_;
    my %meta;

    return \%meta unless -f $path;

    open my $fh, '<', $path or return \%meta;
    while (my $line = <$fh>) {
        $line =~ s/\r?\n\z//;
        next unless index($line, '=') >= 0;
        my ($key, $value) = split /=/, $line, 2;
        $key   =~ s/^\s+|\s+$//g;
        $value =~ s/^\s+|\s+$//g;
        $meta{$key} = $value;
    }
    close $fh;

    return \%meta;
}

sub read_text {
    my ($path) = @_;
    return '' unless -f $path;

    open my $fh, '<', $path or return '';
    local $/;
    my $text = <$fh>;
    close $fh;
    return defined $text ? $text : '';
}

sub has_timeout_evidence {
    my ($run_dir) = @_;
    my $run_out = read_text(File::Spec->catfile($run_dir, 'run.out'));
    return $run_out =~ /^\[host\]\s+timeout after \d+s\s*$/m ? 1 : 0;
}

sub has_log_limit_evidence {
    my ($run_dir) = @_;
    return read_text(File::Spec->catfile($run_dir, 'loglimit.note')) =~ /\S/ ? 1 : 0;
}

sub expected_status {
    my ($rc) = @_;
    return 'PASS'        if $rc == 0;
    return 'UNAVAILABLE' if $rc == 111;
    return 'FAIL';
}

sub integer_or_undef {
    my ($value) = @_;
    return undef unless defined $value && $value =~ /^-?\d+\z/;
    return 0 + $value;
}

my $csv = Text::CSV->new({
    binary    => 1,
    auto_diag => 1,
});

open my $summary_fh, '<:encoding(UTF-8)', $summary
    or die "cannot open $summary: $!\n";

my $header = $csv->getline($summary_fh)
    or die "cannot read CSV header from $summary\n";

$header->[0] =~ s/^\x{FEFF}// if defined $header->[0];
my @expected_header = qw(
    run_id batch base mode module version
    dep_one dep_one_version dep_two dep_two_version
    status rc start_ts end_ts elapsed_s run_dir note
);
die "unexpected summary header in $summary\n"
    unless @$header == @expected_header
        && join("\0", @$header) eq join("\0", @expected_header);
$csv->column_names(@$header);

my @rows;
my @unsupported;
my @indeterminate;
my %seen_run_id;
my %seen_run_dir;
my %counts = (
    SUPPORTED     => 0,
    INDETERMINATE => 0,
    UNSUPPORTED   => 0,
);

my $line_no = 1;
while (my $row = $csv->getline_hr($summary_fh)) {
    ++$line_no;

    my $run_dir_raw = defined $row->{run_dir} ? $row->{run_dir} : '';
    $run_dir_raw =~ s/^\s+|\s+$//g;

    my $run_dir = File::Spec->file_name_is_absolute($run_dir_raw)
        ? $run_dir_raw
        : File::Spec->catdir($batch, $run_dir_raw);
    $run_dir = File::Spec->canonpath(File::Spec->rel2abs($run_dir));

    my $status = defined $row->{status} ? $row->{status} : '';
    my $rc_raw = defined $row->{rc}     ? $row->{rc}     : '';
    $status =~ s/^\s+|\s+$//g;
    $rc_raw =~ s/^\s+|\s+$//g;

    my $run_id = defined $row->{run_id} ? $row->{run_id} : '';
    $run_id =~ s/^\s+|\s+$//g;

    my (@issues, @notes);

    push @issues, "run directory does not exist: $run_dir" unless -d $run_dir;
    push @issues, "missing or invalid run_id: '$run_id'"
        unless $run_id =~ /^\d{6}\z/;
    push @issues, "duplicate summary run_id=$run_id"
        if $run_id ne '' && $seen_run_id{$run_id}++;
    push @issues, "duplicate summary run_dir=$run_dir"
        if $seen_run_dir{$run_dir}++;

    my %allowed_status = map { $_ => 1 } qw(PASS FAIL UNAVAILABLE);
    push @issues, "unknown status '$status'" unless $allowed_status{$status};

    my $rc = integer_or_undef($rc_raw);
    push @issues, "summary rc is not an integer: '$rc_raw'"
        unless defined $rc;

    my $rc_file    = File::Spec->catfile($run_dir, 'rc.code');
    my $meta_file  = File::Spec->catfile($run_dir, 'result.meta');
    my $trail_file = File::Spec->catfile($run_dir, 'execution_trail.audit');
    my $cmd_file   = File::Spec->catfile($run_dir, '00_command.txt');
    my $meta       = read_meta($meta_file);
    my $trail      = read_meta($trail_file);
    my $subtype    = exists $meta->{subtype} ? $meta->{subtype} : '';
    $subtype =~ s/^\s+|\s+$//g;

    push @issues, 'result.meta missing or unreadable' unless -f $meta_file && %$meta;
    push @issues, '00_command.txt missing' unless -f $cmd_file;
    push @issues, 'execution_trail.audit missing or unreadable'
        unless -f $trail_file && %$trail;

    my $file_rc_raw = read_text($rc_file);
    $file_rc_raw =~ s/^\s+|\s+$//g;
    my $file_rc = integer_or_undef($file_rc_raw);
    push @issues, 'rc.code missing or not a single integer'
        unless defined $file_rc;

    if (defined $rc && defined $file_rc && $rc != $file_rc) {
        push @issues, "summary rc=$rc differs from rc.code=$file_rc";
    }

    my $meta_rc = exists $meta->{rc} ? $meta->{rc} : '<missing>';
    push @issues, "result.meta rc=$meta_rc differs from summary rc=$rc_raw"
        if $meta_rc ne $rc_raw;

    my $meta_status = exists $meta->{status} ? $meta->{status} : '<missing>';
    push @issues, "result.meta status=$meta_status differs from summary status=$status"
        if $meta_status ne $status;

    for my $field (qw(run_id batch base mode module version dep_one dep_one_version dep_two dep_two_version run_dir)) {
        my $summary_value = defined $row->{$field} ? $row->{$field} : '';
        my $meta_value = exists $meta->{$field} ? $meta->{$field} : '<missing>';
        push @issues, "result.meta $field=$meta_value differs from summary $field=$summary_value"
            if $meta_value ne $summary_value;
    }

    if (defined $rc) {
        my $expected = expected_status($rc);
        push @issues, "status $status contradicts rc $rc; expected $expected"
            if $status ne $expected;
    }

    my %allowed_subtype = map { $_ => 1 } ('', qw(timeout log_limit_exceeded framework_error));
    push @issues, "unknown result subtype '$subtype'" unless $allowed_subtype{$subtype};
    push @issues, "subtype=timeout requires rc=8"
        if $subtype eq 'timeout' && (!defined $rc || $rc != 8);
    push @issues, "subtype=log_limit_exceeded requires rc=112"
        if $subtype eq 'log_limit_exceeded' && (!defined $rc || $rc != 112);
    push @issues, "subtype=framework_error requires rc=125"
        if $subtype eq 'framework_error' && (!defined $rc || $rc != 125);
    push @issues, 'rc=125 requires subtype=framework_error'
        if defined $rc && $rc == 125 && $subtype ne 'framework_error';

    my @log_names = qw(
        build.log
        run.out
        run.err
        cpanm_work_build.log
        diag.txt
        unavailable.note
        timeout.note
        loglimit.note
        framework_error.note
        framework_error.evidence
    );
    my $logs = join "\n", map { read_text(File::Spec->catfile($run_dir, $_)) } @log_names;
    my $summary_note = defined $row->{note} ? $row->{note} : '';

    if ($status eq 'UNAVAILABLE') {
        my $unavailable_note = File::Spec->catfile($run_dir, 'unavailable.note');
        if (!-f $unavailable_note) {
            push @notes, 'no unavailable.note; rc supports classification but causal evidence is incomplete';
        }
        elsif ($logs !~ /unavailable|not found|could not find|404|no such/i) {
            push @notes, 'unavailable.note exists but no recognizable unavailability marker was found';
        }
    }
    elsif ($status eq 'FAIL') {
        if ($subtype eq 'timeout') {
            push @issues, 'FAIL rc=8 note has no recognizable timeout marker'
                if $summary_note !~ /timeout|timed out/i;
            push @issues, 'FAIL rc=8 has no specific timeout evidence'
                unless has_timeout_evidence($run_dir);
        }
        elsif ($subtype eq 'log_limit_exceeded') {
            push @issues, 'FAIL rc=112 note has no recognizable abort reason'
                if $summary_note !~ /log.*limit|safety limit|aborted/i;
            push @issues, 'FAIL rc=112 has no explicit log-limit evidence'
                unless has_log_limit_evidence($run_dir);
        }
        elsif ($subtype eq 'framework_error') {
            push @issues, 'FAIL subtype=framework_error has no explicit framework-error evidence'
                if $logs !~ /framework|exception|worker.*(?:exit|signal)|signal/i;
        }
        push @notes, 'FAIL has no readable diagnostic log evidence'
            unless $logs =~ /\S/;
    }

    my $result = @issues ? 'UNSUPPORTED'
               : @notes  ? 'INDETERMINATE'
               :           'SUPPORTED';

    ++$counts{$result};

    my $record = {
        line_no => $line_no,
        run_dir => $run_dir,
        status  => $status,
        rc_raw  => $rc_raw,
        result  => $result,
        issues  => \@issues,
        notes   => \@notes,
    };

    push @rows, $record;
    push @unsupported,   $record if @issues;
    push @indeterminate, $record if !@issues && @notes;
}

close $summary_fh;

my $assessment = @unsupported
    ? 'FAIL'
    : @indeterminate
        ? 'PASS WITH LIMITATIONS'
        : 'PASS';

my @lines = (
    'Smoker result classification audit',
    '',
    'Scope:',
    '  Checks whether each reported classification is supported by preserved execution evidence.',
    '  Includes execution-trail and artifact-consistency checks needed to trust the classification.',
    '  Does not assert whether a CPAN module should have passed or failed.',
    '',
    "Batch: $batch",
    "Summary: $summary",
    'Rows audited: ' . scalar(@rows),
    'Classified: ' . $counts{SUPPORTED},
    'Unclassified: ' . ($counts{INDETERMINATE} + $counts{UNSUPPORTED}),
    "SUPPORTED: $counts{SUPPORTED}",
    "INDETERMINATE: $counts{INDETERMINATE}",
    "UNSUPPORTED: $counts{UNSUPPORTED}",
    '',
    "Classification evidence: $assessment",
    '',
);

if (@unsupported) {
    push @lines, 'UNSUPPORTED CLASSIFICATIONS', '-' x 80;
    for my $record (@unsupported) {
        push @lines,
            "summary line $record->{line_no} | $record->{run_dir} | "
            . "status=$record->{status} rc=$record->{rc_raw}";
        push @lines, map { "  ERROR: $_" } @{ $record->{issues} };
    }
    push @lines, '';
}

if (@indeterminate) {
    push @lines, 'INDETERMINATE CLASSIFICATIONS', '-' x 80;
    for my $record (@indeterminate) {
        push @lines,
            "summary line $record->{line_no} | $record->{run_dir} | "
            . "status=$record->{status} rc=$record->{rc_raw}";
        push @lines, map { "  LIMITATION: $_" } @{ $record->{notes} };
    }
    push @lines, '';
}

push @lines, 'RESULT TABLE', '-' x 80;
for my $record (@rows) {
    push @lines, join "\t",
        basename($record->{run_dir}),
        $record->{status},
        $record->{rc_raw},
        $record->{result};
}

open my $out_fh, '>:encoding(UTF-8)', $output
    or die "cannot write $output: $!\n";
print {$out_fh} join("\n", @lines), "\n";
close $out_fh or die "cannot close $output: $!\n";

print "Report written: $output\n";
print "Classification evidence: $assessment\n";
print "Classified=$counts{SUPPORTED} Unclassified=" . ($counts{INDETERMINATE} + $counts{UNSUPPORTED}) . "\n";
print "Supported=$counts{SUPPORTED} Indeterminate=$counts{INDETERMINATE} Unsupported=$counts{UNSUPPORTED}\n";

exit(@unsupported ? 1 : 0);
