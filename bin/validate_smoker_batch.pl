#!/usr/bin/env perl
use strict;
use warnings;

use Cwd qw(abs_path);
use File::Basename qw(basename dirname);
use File::Find qw(find);
use File::Path qw(make_path);
use File::Spec;
use FindBin qw($Bin);
use List::Util qw(min max sum);
use POSIX qw(strftime);
use Text::CSV;
use lib "$Bin/../lib";
use Smoker::PlanCSV qw(canonical_row_key row_is_comment);

sub usage {
    die "usage: " . basename($0) . " [BATCH_DIR] [OUTPUT_FILE]\n";
}

sub die_error {
    my ($msg) = @_;
    die "ERROR: $msg\n";
}

sub read_text {
    my ($path) = @_;
    return undef unless -f $path;
    open my $fh, '<:raw', $path or return undef;
    local $/;
    my $text = <$fh>;
    close $fh;
    return $text;
}

sub has_timeout_evidence {
    my ($run_dir) = @_;
    my $run_out = read_text(File::Spec->catfile($run_dir, 'run.out')) // '';
    return $run_out =~ /^\[host\]\s+timeout after \d+s\s*$/m ? 1 : 0;
}

sub has_log_limit_evidence {
    my ($run_dir) = @_;
    my $note = read_text(File::Spec->catfile($run_dir, 'loglimit.note')) // '';
    return $note =~ /\S/ ? 1 : 0;
}

sub read_meta_subtype {
    my ($run_dir) = @_;
    my $text = read_text(File::Spec->catfile($run_dir, 'result.meta')) // '';
    for my $line (split /\r?\n/, $text) {
        next unless $line =~ /^subtype=(.*)$/;
        my $subtype = $1;
        $subtype =~ s/^\s+|\s+$//g;
        return $subtype;
    }
    return '';
}

sub read_kv_text {
    my ($text) = @_;
    my %kv;
    $text = '' unless defined $text;
    for my $line (split /\r?\n/, $text) {
        next unless index($line, '=') >= 0;
        my ($key, $value) = split /=/, $line, 2;
        $key   =~ s/^\s+|\s+$//g;
        $value =~ s/^\s+|\s+$//g;
        $kv{$key} = $value;
    }
    return \%kv;
}

sub integer_or_undef {
    my ($value) = @_;
    return undef unless defined $value;
    $value =~ s/^\s+|\s+$//g;
    return undef unless $value =~ /^-?\d+$/;
    return 0 + $value;
}

sub add_wait_evidence_issues {
    my ($issues, $meta, $evidence) = @_;

    my $meta_raw = $meta->{raw_wait_status} // '';
    my $ev_raw   = $evidence->{raw_wait_status} // '';
    my $meta_sig = $meta->{interrupt_signal} // '';
    my $ev_sig   = $evidence->{interrupt_signal} // $evidence->{signal} // '';
    my $ev_core  = $evidence->{core_dumped} // '';
    my $ev_pid   = $evidence->{worker_pid} // '';
    my $stage    = $evidence->{stage} // '';
    my $reason   = $evidence->{reason} // '';

    if ($meta_raw ne '' && !defined integer_or_undef($meta_raw)) {
        push @$issues, 'raw wait status is not an integer';
    }
    if ($ev_raw ne '' && !defined integer_or_undef($ev_raw)) {
        push @$issues, 'framework evidence raw wait status is not an integer';
    }
    if ($meta_raw ne '' && $ev_raw ne '' && $meta_raw ne $ev_raw) {
        push @$issues, 'raw wait status mismatch between result.meta and framework evidence';
    }

    my $raw = integer_or_undef($meta_raw ne '' ? $meta_raw : $ev_raw);
    if (defined $raw) {
        my $decoded_exit = $raw >> 8;
        my $decoded_signal = $raw & 127;
        my $decoded_core = ($raw & 128) ? 1 : 0;

        if (($meta->{raw_return_code} // '') ne ''
            && defined integer_or_undef($meta->{raw_return_code})
            && integer_or_undef($meta->{raw_return_code}) != $decoded_exit) {
            push @$issues, 'raw wait status exit code disagrees with raw_return_code';
        }

        if ($meta_sig ne ''
            && defined integer_or_undef($meta_sig)
            && integer_or_undef($meta_sig) != $decoded_signal) {
            push @$issues, 'signal mismatch between raw wait status and result.meta';
        }
        if ($ev_sig ne ''
            && defined integer_or_undef($ev_sig)
            && integer_or_undef($ev_sig) != $decoded_signal) {
            push @$issues, 'signal mismatch between raw wait status and framework evidence';
        }
        if ($ev_core ne ''
            && defined integer_or_undef($ev_core)
            && integer_or_undef($ev_core) != $decoded_core) {
            push @$issues, 'core-dump mismatch between raw wait status and framework evidence';
        }
    }

    if ($reason =~ /fork/i || $stage eq 'fork') {
        push @$issues, 'fork failure framework evidence is missing stage=fork'
            unless $stage eq 'fork';
        push @$issues, 'fork failure must not claim a worker PID'
            if $ev_pid ne '' && $ev_pid !~ /unavailable|no worker/i;
        push @$issues, 'fork failure must explicitly state no worker PID existed'
            unless ($evidence->{worker_pid_unavailable} // '') =~ /no worker PID/i;
        push @$issues, 'fork failure must explicitly state no wait status existed'
            unless ($evidence->{wait_status_unavailable} // '') =~ /no wait status/i;
    }
}

sub write_text {
    my ($path, $text) = @_;
    open my $fh, '>:encoding(UTF-8)', $path
        or die_error("cannot write $path: $!");
    print {$fh} $text;
    close $fh or die_error("cannot close $path: $!");
}

sub canon_abs {
    my ($path) = @_;
    my $abs = File::Spec->rel2abs($path);
    return abs_path($abs) // File::Spec->canonpath($abs);
}

sub newest_batch_dir {
    my ($root) = @_;
    return undef unless -d $root;

    opendir my $dh, $root or return undef;
    my @dirs;
    while (my $name = readdir $dh) {
        next if $name eq '.' || $name eq '..';
        my $path = File::Spec->catdir($root, $name);
        next unless -d $path;
        my @st = stat($path);
        push @dirs, [$st[9] // 0, $path];
    }
    closedir $dh;

    return undef unless @dirs;
    @dirs = sort { $b->[0] <=> $a->[0] } @dirs;
    return $dirs[0][1];
}

sub read_csv {
    my ($path, %args) = @_;
    my $csv = Text::CSV->new({
        binary    => 1,
        auto_diag => 1,
    });

    open my $fh, '<:encoding(UTF-8)', $path
        or die_error("cannot open CSV $path: $!");

    my $header = $csv->getline($fh);
    if (!$header) {
        close $fh;
        return ([], []);
    }

    $header->[0] =~ s/^\x{FEFF}// if defined $header->[0];
    $csv->column_names(@$header);

    my @rows;
    while (my $row = $csv->getline_hr($fh)) {
        if ($args{skip_comments}) {
            my @fields = map { $row->{$_} } @$header;
            next if row_is_comment(\@fields);
        }
        push @rows, $row;
    }
    close $fh;

    return ($header, \@rows);
}

sub read_raw_csv_rows {
    my ($path) = @_;
    my $csv = Text::CSV->new({
        binary    => 1,
        auto_diag => 1,
    });

    open my $fh, '<:encoding(UTF-8)', $path
        or die_error("cannot open CSV $path: $!");

    my @rows;
    while (my $row = $csv->getline($fh)) {
        push @rows, [@$row];
    }
    close $fh;

    shift @rows if @rows;
    @rows = grep { !row_is_comment($_) } @rows;
    return \@rows;
}

sub row_key {
    my ($row) = @_;
    return canonical_row_key($row);
}

sub normalize_status {
    my ($value) = @_;
    $value = '' unless defined $value;
    $value =~ s/^\s+|\s+$//g;
    return length($value) ? $value : '<blank>';
}

sub normalize_rc {
    my ($value) = @_;
    $value = '' unless defined $value;
    $value =~ s/^\s+|\s+$//g;
    return length($value) ? $value : '<blank>';
}

sub status_rc_consistent {
    my ($status, $rc) = @_;

    $status = normalize_status($status);
    $rc     = normalize_rc($rc);

    return 0 unless $rc =~ /^-?\d+$/;

    return $rc == 0
        if $status eq 'PASS';

    return $rc == 111
        if $status eq 'UNAVAILABLE';

    return $rc != 0 && $rc != 111
        if $status eq 'FAIL';

    return 0;
}

sub parse_number {
    my ($value) = @_;
    return undef unless defined $value;
    $value =~ s/^\s+|\s+$//g;
    return undef unless $value =~ /^-?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?$/;
    my $n = 0 + $value;
    return undef if $n != $n;
    return $n;
}

sub percentile {
    my ($sorted, $p) = @_;
    return undef unless @$sorted;
    return $sorted->[0] if @$sorted == 1;

    my $k = (@$sorted - 1) * $p;
    my $lo = int($k);
    my $hi = $k == int($k) ? int($k) : int($k) + 1;

    return $sorted->[$lo] if $lo == $hi;
    return $sorted->[$lo] * ($hi - $k) + $sorted->[$hi] * ($k - $lo);
}

sub median {
    my ($sorted) = @_;
    return undef unless @$sorted;
    my $n = @$sorted;
    return $sorted->[int($n / 2)] if $n % 2;
    return ($sorted->[$n/2 - 1] + $sorted->[$n/2]) / 2;
}

sub rel_path {
    my ($path, $base) = @_;
    my $rel = File::Spec->abs2rel($path, $base);
    return $rel =~ /^\.\./ ? $path : $rel;
}

sub recursive_files_named {
    my ($root, $name) = @_;
    my @files;
    return \@files unless -d $root;

    find(
        {
            no_chdir => 1,
            wanted   => sub {
                return unless -f $_;
                push @files, canon_abs($_) if basename($_) eq $name;
            },
        },
        $root
    );

    @files = sort @files;
    return \@files;
}

sub immediate_subdirs {
    my ($root) = @_;
    return [] unless -d $root;

    opendir my $dh, $root or return [];
    my @dirs;
    while (my $name = readdir $dh) {
        next if $name eq '.' || $name eq '..';
        my $path = File::Spec->catdir($root, $name);
        push @dirs, canon_abs($path) if -d $path;
    }
    closedir $dh;

    @dirs = sort @dirs;
    return \@dirs;
}

sub file_quality {
    my ($path, $kind) = @_;
    my @issues;

    return ['missing'] unless -e $path;
    return ['not_regular_file'] unless -f $path;
    return ['empty'] unless -s $path;

    my $text = read_text($path);
    return ['unreadable'] unless defined $text;

    if ($kind eq 'rc.code') {
        my $trim = $text;
        $trim =~ s/^\s+|\s+$//g;
        push @issues, 'not_single_integer' unless $trim =~ /^-?\d+$/;
        push @issues, 'contains_nul' if index($text, "\0") >= 0;
    }
    elsif ($kind eq 'result.meta') {
        push @issues, 'contains_nul' if index($text, "\0") >= 0;

        my %keys;
        my $malformed = 0;
        for my $line (grep { /\S/ } split /\r?\n/, $text) {
            if (index($line, '=') < 0) {
                ++$malformed;
                next;
            }
            my ($key) = split /=/, $line, 2;
            $key =~ s/^\s+|\s+$//g;
            $keys{$key} = 1;
        }

        push @issues, "lines_without_equals=$malformed" if $malformed;
        for my $required (qw(status rc)) {
            push @issues, "missing_key:$required" unless $keys{$required};
        }
    }

    return \@issues;
}

sub resolve_run_dir {
    my ($raw, $batch) = @_;
    return undef unless defined $raw;

    $raw =~ s/^\s+|\s+$//g;
    return undef unless length $raw;

    my @candidates;
    if (File::Spec->file_name_is_absolute($raw)) {
        push @candidates, $raw;
    }
    else {
        push @candidates,
            File::Spec->catdir($batch, $raw),
            File::Spec->catdir($batch, 'runs', $raw),
            File::Spec->catdir(dirname($batch), $raw);
    }

    for my $candidate (@candidates) {
        return canon_abs($candidate) if -d $candidate;
    }

    return canon_abs($candidates[0]);
}

sub is_plan_csv {
    my ($path) = @_;
    my $name = lc basename($path);

    return 0 if $name eq 'summary.csv'
             || $name eq 'skipped_dup.csv'
             || $name eq 'remaining.csv'
             || $name eq 'unique.csv';
    return 0 if $name =~ /summary|skipped|remaining|unique/;

    my ($fields, $rows);
    eval { ($fields, $rows) = read_csv($path); 1 } or return 0;
    my %field = map { $_ => 1 } @$fields;

    return $field{batch} && $field{base} && $field{mode} && $field{module};
}

sub find_plan {
    my ($batch) = @_;
    my $preserved = File::Spec->catfile($batch, 'original_plan.csv');
    return (canon_abs($preserved), 1) if -f $preserved;

    my $name = basename($batch);
    (my $stem = $name) =~ s/_\d{8}_\d{6}$//;

    my $project_root = canon_abs(File::Spec->catdir($batch, '..', '..'));
    my @candidates = (
        File::Spec->catfile($project_root, 'config', 'plans', "$stem.csv"),
        File::Spec->catfile($ENV{HOME} // '', 'Smoker', 'development', 'config', 'plans', "$stem.csv"),
    );

    for my $candidate (@candidates) {
        return (canon_abs($candidate), 0) if -f $candidate;
    }

    opendir my $dh, $batch or return (undef, 0);
    my @local = sort map { File::Spec->catfile($batch, $_) }
                grep { /\.csv$/i && -f File::Spec->catfile($batch, $_) }
                readdir $dh;
    closedir $dh;

    for my $preferred (qw(original_plan.csv plan.csv input.csv)) {
        for my $candidate (@local) {
            return (canon_abs($candidate), 1)
                if basename($candidate) eq $preferred && is_plan_csv($candidate);
        }
    }

    for my $candidate (@local) {
        return (canon_abs($candidate), 1) if is_plan_csv($candidate);
    }

    return (undef, 0);
}

sub write_counter {
    my ($lines, $title, $counter, $limit) = @_;
    push @$lines, $title;

    if (!%$counter) {
        push @$lines, '  <none>';
        return;
    }

    my @items = sort {
        $counter->{$b} <=> $counter->{$a}
            || $a cmp $b
    } keys %$counter;

    splice @items, $limit if defined($limit) && @items > $limit;
    push @$lines, map { sprintf("  %8d  %s", $counter->{$_}, $_) } @items;
}

@ARGV <= 2 or usage();

my $script_dir  = canon_abs(dirname($0));
my $smoker_home = canon_abs(File::Spec->catdir($script_dir, '..'));

my $batch = @ARGV >= 1
    ? $ARGV[0]
    : newest_batch_dir(File::Spec->catdir($smoker_home, 'test_results'));

defined $batch && length $batch
    or die_error("no batch directory supplied and none found under "
        . File::Spec->catdir($smoker_home, 'test_results'));

$batch = canon_abs($batch);
-d $batch or die_error("batch directory does not exist: $batch");

my $output = @ARGV == 2
    ? canon_abs($ARGV[1])
    : File::Spec->catfile($batch, 'validation_evidence.txt');

my $output_parent = dirname($output);
make_path($output_parent) unless -d $output_parent;
$output = canon_abs($output);

my $classification_report = File::Spec->catfile($batch, 'result_classification_audit.txt');
my $classification_evidence = 'DERIVED';
my $classification_detail   = 'classification support derived from batch artifacts';
my $classified_count        = 0;
my $unclassified_count      = 0;

if (-f $classification_report) {
    my $classification_text = read_text($classification_report) // '';
    $classification_detail =
        'classification audit file present but producer/audit verdicts are not trusted by batch validation';
}

my $summary   = File::Spec->catfile($batch, 'summary.csv');
my $skipped   = File::Spec->catfile($batch, 'skipped_dup.csv');
my $runs_root = File::Spec->catdir($batch, 'runs');
my ($plan, $plan_preserved_in_batch) = find_plan($batch);

my @errors;
push @errors, "missing required file: $summary" unless -f $summary;
push @errors, "missing required directory: $runs_root" unless -d $runs_root;
push @errors, 'could not locate the original plan CSV' unless defined $plan;

if (@errors) {
    write_text(
        $output,
        "Smoker batch validation evidence\n\n"
        . join('', map { "ERROR: $_\n" } @errors)
    );
    print STDERR join("\n", @errors), "\n";
    exit 2;
}

opendir my $batch_dh, $batch or die_error("cannot read $batch: $!");
my @all_csvs = sort map { File::Spec->catfile($batch, $_) }
               grep { /\.csv$/i && -f File::Spec->catfile($batch, $_) }
               readdir $batch_dh;
closedir $batch_dh;

my ($unique_csv) = grep {
    my $name = lc basename($_);
    $name ne 'summary.csv'
        && $name ne 'skipped_dup.csv'
        && $name =~ /remaining|unique|dedup/
} @all_csvs;

my ($plan_fields,    $plan_rows)    = read_csv($plan, skip_comments => 1);
my ($summary_fields, $summary_rows) = read_csv($summary);
my @expected_summary_fields = qw(
    run_id batch base mode module version
    dep_one dep_one_version dep_two dep_two_version
    status rc start_ts end_ts elapsed_s run_dir note
);
my $summary_schema_exact =
    @$summary_fields == @expected_summary_fields
    && join("\0", @$summary_fields) eq join("\0", @expected_summary_fields);

my ($skipped_fields, $skipped_rows) = ([], []);
($skipped_fields, $skipped_rows) = read_csv($skipped) if -f $skipped;

my ($unique_fields, $unique_rows) = ([], []);
($unique_fields, $unique_rows) = read_csv($unique_csv, skip_comments => 1)
    if defined $unique_csv;

my $run_dirs   = immediate_subdirs($runs_root);
my $rc_files   = recursive_files_named($runs_root, 'rc.code');
my $meta_files = recursive_files_named($runs_root, 'result.meta');
my $audit_files = recursive_files_named($runs_root, 'execution_trail.audit');

my $summary_raw = read_raw_csv_rows($summary);
my %summary_dup_counter;
++$summary_dup_counter{row_key($_)} for @$summary_raw;
my $summary_duplicate_groups = scalar grep { $_ > 1 } values %summary_dup_counter;
my $summary_duplicate_extra_rows = sum(map { $_ > 1 ? $_ - 1 : 0 } values %summary_dup_counter) // 0;

my (@unique_raw, %unique_dup_counter);
my ($unique_duplicate_groups, $unique_duplicate_extra_rows) = (0, 0);
if (defined $unique_csv) {
    my $rows = read_raw_csv_rows($unique_csv);
    @unique_raw = @$rows;
    ++$unique_dup_counter{row_key($_)} for @unique_raw;
    $unique_duplicate_groups = scalar grep { $_ > 1 } values %unique_dup_counter;
    $unique_duplicate_extra_rows =
        sum(map { $_ > 1 ? $_ - 1 : 0 } values %unique_dup_counter) // 0;
}

my $plan_raw = read_raw_csv_rows($plan);
my %seen_plan;
my (@computed_unique_raw, @computed_skipped_raw);
for my $row (@$plan_raw) {
    my $key = row_key($row);
    if ($seen_plan{$key}++) {
        push @computed_skipped_raw, $row;
    }
    else {
        push @computed_unique_raw, $row;
    }
}

my $original_plan_rows   = scalar @$plan_raw;
my $computed_unique_rows = scalar @computed_unique_raw;
my $computed_removed_rows = scalar @computed_skipped_raw;
my $dedup_accounting_pass =
    $original_plan_rows == $computed_unique_rows + $computed_removed_rows;

my $unique_csv_matches_computed = 0;
if (defined $unique_csv) {
    $unique_csv_matches_computed =
        @unique_raw == @computed_unique_raw
        && !grep {
            row_key($unique_raw[$_]) ne row_key($computed_unique_raw[$_])
        } 0 .. $#unique_raw;
}

my $skipped_csv_matches_computed;
if (-f $skipped) {
    my $skipped_raw = read_raw_csv_rows($skipped);
    $skipped_csv_matches_computed =
        @$skipped_raw == @computed_skipped_raw
        && !grep {
            row_key($skipped_raw->[$_]) ne row_key($computed_skipped_raw[$_])
        } 0 .. $#$skipped_raw;
}

my %summary_field = map { $_ => 1 } @$summary_fields;
my ($run_dir_col) = grep { $summary_field{$_} }
                    qw(run_dir run_directory directory result_dir);

my (@summary_resolved_paths, @missing_summary_run_dirs, @unresolved_summary_run_dirs);
if ($run_dir_col) {
    for my $i (0 .. $#$summary_rows) {
        my $raw = $summary_rows->[$i]{$run_dir_col} // '';
        my $resolved = resolve_run_dir($raw, $batch);
        push @summary_resolved_paths, [$i + 2, $raw, $resolved];

        if (!defined $resolved) {
            push @unresolved_summary_run_dirs, [$i + 2, $raw];
        }
        elsif (!-d $resolved) {
            push @missing_summary_run_dirs, [$i + 2, $raw, $resolved];
        }
    }
}
else {
    push @unresolved_summary_run_dirs,
        [0, 'no run directory column in summary'];
}

my %summary_path_counter;
for my $entry (@summary_resolved_paths) {
    my $resolved = $entry->[2];
    ++$summary_path_counter{$resolved} if defined $resolved;
}

my %summary_duplicate_run_refs =
    map { $_ => $summary_path_counter{$_} }
    grep { $summary_path_counter{$_} > 1 }
    keys %summary_path_counter;

my @run_dirs_not_in_summary =
    grep { !$summary_path_counter{$_} } @$run_dirs;

my @run_dirs_multiple =
    map { [$_, $summary_path_counter{$_}] }
    grep { ($summary_path_counter{$_} // 0) > 1 }
    @$run_dirs;

my (@run_integrity_issues, @rc_meta_mismatches);
for my $run_dir (@$run_dirs) {
    my $rc_path    = File::Spec->catfile($run_dir, 'rc.code');
    my $meta_path  = File::Spec->catfile($run_dir, 'result.meta');
    my $audit_path = File::Spec->catfile($run_dir, 'execution_trail.audit');

    my $rc_issues   = file_quality($rc_path, 'rc.code');
    my $meta_issues = file_quality($meta_path, 'result.meta');
    my @audit_issues;

    if (!-f $audit_path) {
        push @audit_issues, 'missing';
    }
    else {
        my $audit_text = read_text($audit_path) // '';
        push @audit_issues, 'empty' unless $audit_text =~ /\S/;
    }

    if (@$rc_issues || @$meta_issues || @audit_issues) {
        push @run_integrity_issues,
            [$run_dir, $rc_issues, $meta_issues, \@audit_issues];
    }

    my $rc_text = read_text($rc_path);
    my $meta_text = read_text($meta_path);
    next unless defined $rc_text && defined $meta_text;

    $rc_text =~ s/^\s+|\s+$//g;
    next unless $rc_text =~ /^-?\d+$/;

    my %meta;
    for my $line (split /\r?\n/, $meta_text) {
        next unless index($line, '=') >= 0;
        my ($key, $value) = split /=/, $line, 2;
        $key   =~ s/^\s+|\s+$//g;
        $value =~ s/^\s+|\s+$//g;
        $meta{$key} = $value;
    }

    if (exists $meta{rc} && $meta{rc} ne $rc_text) {
        push @rc_meta_mismatches, [$run_dir, $rc_text, $meta{rc}];
    }
}

my (%status_counter, %rc_counter, %status_rc_counter);
for my $row (@$summary_rows) {
    my $status = normalize_status($row->{status});
    my $rc = normalize_rc($row->{rc});
    ++$status_counter{$status};
    ++$rc_counter{$rc};
    ++$status_rc_counter{"$status | rc=$rc"};
}

my @summary_rc_file_mismatches;
if ($run_dir_col && $summary_field{rc}) {
    for my $entry (@summary_resolved_paths) {
        my ($line_no, $raw, $resolved) = @$entry;
        next unless defined $resolved && -d $resolved;

        my $rc_path = File::Spec->catfile($resolved, 'rc.code');
        next unless -f $rc_path;

        my $file_rc = read_text($rc_path);
        next unless defined $file_rc;
        $file_rc =~ s/^\s+|\s+$//g;

        my $summary_rc = $summary_rows->[$line_no - 2]{rc} // '';
        $summary_rc =~ s/^\s+|\s+$//g;

        if ($file_rc ne $summary_rc) {
            push @summary_rc_file_mismatches,
                [$line_no, $raw, $summary_rc, $file_rc];
        }
    }
}

my (
    @summary_meta_status_mismatches,
    @summary_meta_rc_mismatches,
    @summary_status_rc_mismatches,
    @meta_status_rc_mismatches,
    @special_result_evidence_issues,
);

my %consistency_issue_runs;
my %classification_issue_lines;

if ($run_dir_col && $summary_field{status} && $summary_field{rc}) {
    for my $entry (@summary_resolved_paths) {
        my ($line_no, $raw, $resolved) = @$entry;
        next unless defined $resolved && -d $resolved;

        my $row = $summary_rows->[$line_no - 2];

        my $summary_status = normalize_status($row->{status});
        my $summary_rc     = normalize_rc($row->{rc});

        if (!status_rc_consistent($summary_status, $summary_rc)) {
            push @summary_status_rc_mismatches,
                [$line_no, $raw, $summary_status, $summary_rc];

            $consistency_issue_runs{$resolved} = 1;
            $classification_issue_lines{$line_no} = 1;
        }

        my $summary_note = defined $row->{note} ? $row->{note} : '';
        my $evidence_text = join "\n", map {
            read_text(File::Spec->catfile($resolved, $_)) // ''
        } qw(
            build.log run.out run.err timeout.note loglimit.note
            framework_error.note framework_error.evidence
        );

        my @evidence_issues;
        my $subtype = read_meta_subtype($resolved);
        my %allowed_subtype = map { $_ => 1 } ('', qw(timeout log_limit_exceeded framework_error));
        push @evidence_issues, "unknown result subtype '$subtype'"
            unless $allowed_subtype{$subtype};
        push @evidence_issues, 'subtype=timeout requires rc=8'
            if $subtype eq 'timeout' && $summary_rc ne '8';
        push @evidence_issues, 'subtype=log_limit_exceeded requires rc=112'
            if $subtype eq 'log_limit_exceeded' && $summary_rc ne '112';
        push @evidence_issues, 'subtype=framework_error requires rc=125'
            if $subtype eq 'framework_error' && $summary_rc ne '125';
        push @evidence_issues, 'rc=125 requires subtype=framework_error'
            if $summary_rc eq '125' && $subtype ne 'framework_error';

        if ($summary_status eq 'FAIL' && $subtype eq 'timeout') {
            push @evidence_issues, 'note lacks timeout reason'
                unless $summary_note =~ /timeout|timed out/i;
            push @evidence_issues, 'run evidence lacks specific timeout marker'
                unless has_timeout_evidence($resolved);
        }
        elsif ($summary_status eq 'FAIL' && $subtype eq 'log_limit_exceeded') {
            push @evidence_issues, 'note lacks abort reason'
                unless $summary_note =~ /log.*limit|safety limit|aborted/i;
            push @evidence_issues, 'run evidence lacks explicit log-limit marker'
                unless has_log_limit_evidence($resolved);
        }
        elsif ($summary_status eq 'FAIL' && $subtype eq 'framework_error') {
            my $meta_path = File::Spec->catfile($resolved, 'result.meta');
            my $meta_text = read_text($meta_path);
            my $meta_kv = read_kv_text($meta_text);
            my $framework_text =
                (read_text(File::Spec->catfile($resolved, 'framework_error.evidence')) // '')
                . "\n"
                . (read_text(File::Spec->catfile($resolved, 'framework_error.note')) // '');
            my $framework_kv = read_kv_text($framework_text);

            push @evidence_issues, 'explicit framework-error evidence is absent'
                unless $evidence_text =~ /framework|exception|worker.*(?:exit|signal)|signal/i;
            push @evidence_issues, 'framework-error reason is absent'
                unless ($meta_kv->{note} // '') =~ /\S/
                    && (($framework_kv->{reason} // '') =~ /\S/
                        || $framework_text =~ /exception|worker|signal|fork/i);

            add_wait_evidence_issues(\@evidence_issues, $meta_kv, $framework_kv);
        }

        if (@evidence_issues) {
            push @special_result_evidence_issues,
                [$line_no, $raw, \@evidence_issues];
            $consistency_issue_runs{$resolved} = 1;
            $classification_issue_lines{$line_no} = 1;
        }

        my $meta_path = File::Spec->catfile($resolved, 'result.meta');
        my $meta_text = read_text($meta_path);
        next unless defined $meta_text;

        my %meta;
        for my $line (split /\r?\n/, $meta_text) {
            next unless index($line, '=') >= 0;

            my ($key, $value) = split /=/, $line, 2;
            $key   =~ s/^\s+|\s+$//g;
            $value =~ s/^\s+|\s+$//g;
            $meta{$key} = $value;
        }

        my $meta_status = normalize_status($meta{status});
        my $meta_rc     = normalize_rc($meta{rc});

        if ($summary_status ne $meta_status) {
            push @summary_meta_status_mismatches,
                [$line_no, $raw, $summary_status, $meta_status];

            $consistency_issue_runs{$resolved} = 1;
            $classification_issue_lines{$line_no} = 1;
        }

        if ($summary_rc ne $meta_rc) {
            push @summary_meta_rc_mismatches,
                [$line_no, $raw, $summary_rc, $meta_rc];

            $consistency_issue_runs{$resolved} = 1;
            $classification_issue_lines{$line_no} = 1;
        }

        if (!status_rc_consistent($meta_status, $meta_rc)) {
            push @meta_status_rc_mismatches,
                [$line_no, $raw, $meta_status, $meta_rc];

            $consistency_issue_runs{$resolved} = 1;
            $classification_issue_lines{$line_no} = 1;
        }

        my $audit_path = File::Spec->catfile($resolved, 'execution_trail.audit');
        my $audit_kv = read_kv_text(read_text($audit_path));
        my @trail_issues;
        push @trail_issues, 'execution-trail run_id contradicts summary'
            if exists $audit_kv->{run_id}
                && $audit_kv->{run_id} ne ''
                && $audit_kv->{run_id} ne ($row->{run_id} // '');
        push @trail_issues, 'execution-trail rc contradicts summary'
            if exists $audit_kv->{rc}
                && $audit_kv->{rc} ne ''
                && $audit_kv->{rc} ne ($row->{rc} // '');
        push @trail_issues, 'execution-trail status contradicts summary'
            if exists $audit_kv->{status}
                && $audit_kv->{status} ne ''
                && $audit_kv->{status} ne ($row->{status} // '');

        if (@trail_issues) {
            push @special_result_evidence_issues,
                [$line_no, $raw, \@trail_issues];
            $consistency_issue_runs{$resolved} = 1;
            $classification_issue_lines{$line_no} = 1;
        }
    }
}

my ($elapsed_col) = grep { $summary_field{$_} }
                    qw(elapsed_s elapsed duration_s duration);
my (@timings, @timing_rows, @invalid_timing_rows);

if ($elapsed_col) {
    for my $i (0 .. $#$summary_rows) {
        my $value = parse_number($summary_rows->[$i]{$elapsed_col});
        if (!defined $value || $value < 0) {
            push @invalid_timing_rows,
                [$i + 2, $summary_rows->[$i]{$elapsed_col}];
        }
        else {
            push @timings, $value;
            push @timing_rows, [$value, $i + 2, $summary_rows->[$i]];
        }
    }
}

my @timings_sorted = sort { $a <=> $b } @timings;
my %timing_stats;
my ($slow_threshold, @slow_rows);

if (@timings_sorted) {
    $timing_stats{count}  = scalar @timings_sorted;
    $timing_stats{min}    = $timings_sorted[0];
    $timing_stats{max}    = $timings_sorted[-1];
    $timing_stats{mean}   = sum(@timings_sorted) / @timings_sorted;
    $timing_stats{median} = median(\@timings_sorted);
    $timing_stats{p90}    = percentile(\@timings_sorted, 0.90);
    $timing_stats{p95}    = percentile(\@timings_sorted, 0.95);
    $timing_stats{p99}    = percentile(\@timings_sorted, 0.99);

    my $q1 = percentile(\@timings_sorted, 0.25);
    my $q3 = percentile(\@timings_sorted, 0.75);
    my $iqr = $q3 - $q1;
    $slow_threshold = max($timing_stats{p99}, $q3 + 3 * $iqr);

    @slow_rows = sort { $b->[0] <=> $a->[0] }
                 grep { $_->[0] >= $slow_threshold }
                 @timing_rows;
    splice @slow_rows, 50 if @slow_rows > 50;
}

my @failure_rows = grep {
    uc(normalize_status($_->{status})) ne 'PASS'
        || normalize_rc($_->{rc}) !~ /^(?:0|<blank>)$/
} @$summary_rows;

sub group_failures {
    my ($rows, $column, $fields) = @_;
    return {} unless $fields->{$column};

    my %counter;
    for my $row (@$rows) {
        my $value = $row->{$column} // '';
        $value =~ s/^\s+|\s+$//g;
        $value = '<blank>' unless length $value;
        ++$counter{$value};
    }
    return \%counter;
}

sub group_dependency_versions {
    my ($rows, $name_column, $version_column, $fields) = @_;
    return {} unless $fields->{$name_column} && $fields->{$version_column};

    my %counter;
    for my $row (@$rows) {
        my $name = $row->{$name_column} // '';
        my $version = $row->{$version_column} // '';
        $name =~ s/^\s+|\s+$//g;
        $version =~ s/^\s+|\s+$//g;
        next unless length($name) || length($version);

        my $rendered_name = length($name) ? $name : '<blank dependency>';
        my $rendered_version = length($version) ? $version : '<blank version>';
        ++$counter{"$rendered_name  $rendered_version"};
    }
    return \%counter;
}

my @failure_group_columns =
    qw(module version dep_one dep_two base mode status rc);
my %failure_groups =
    map { $_ => group_failures(\@failure_rows, $_, \%summary_field) }
    @failure_group_columns;

my $dep_one_version_failures =
    group_dependency_versions(
        \@failure_rows, 'dep_one', 'dep_one_version', \%summary_field
    );

my $dep_two_version_failures =
    group_dependency_versions(
        \@failure_rows, 'dep_two', 'dep_two_version', \%summary_field
    );

my %basename_counter;
++$basename_counter{basename($_)} for @$run_dirs;
my %duplicate_basenames =
    map { $_ => $basename_counter{$_} }
    grep { $basename_counter{$_} > 1 }
    keys %basename_counter;

my @identity_columns = grep { $summary_field{$_} }
    qw(batch base mode module version dep_one dep_one_version dep_two dep_two_version);

my %logical_counter;
for my $row (@$summary_rows) {
    my $key = join "\x1E",
        map {
            my $value = $row->{$_} // '';
            $value =~ s/^\s+|\s+$//g;
            $value;
        } @identity_columns;
    ++$logical_counter{$key};
}

my @repeated_logical_tests =
    sort {
        $logical_counter{$b} <=> $logical_counter{$a}
            || $a cmp $b
    }
    grep { $logical_counter{$_} > 1 }
    keys %logical_counter;

my %counts = (
    original_plan_rows          => $original_plan_rows,
    deduplicated_plan_rows      => defined($unique_csv) ? scalar(@$unique_rows) : undef,
    computed_unique_rows        => $computed_unique_rows,
    computed_removed_rows       => $computed_removed_rows,
    summary_rows                => scalar(@$summary_rows),
    run_directories             => scalar(@$run_dirs),
    rc_code_files               => scalar(@$rc_files),
    result_meta_files           => scalar(@$meta_files),
    execution_trail_audit_files => scalar(@$audit_files),
);

my $executed_plan_rows =
    defined($unique_csv) ? scalar(@$unique_rows) : $computed_unique_rows;

my $execution_counts_equal =
    $executed_plan_rows == $counts{summary_rows}
    && $executed_plan_rows == $counts{run_directories}
    && $executed_plan_rows == $counts{rc_code_files}
    && $executed_plan_rows == $counts{result_meta_files}
    && $executed_plan_rows == $counts{execution_trail_audit_files};

my $execution_relationships_clean =
    !@missing_summary_run_dirs
    && !@unresolved_summary_run_dirs
    && !@run_dirs_not_in_summary
    && !@run_dirs_multiple
    && !%summary_duplicate_run_refs
    && !@run_integrity_issues
    && !@rc_meta_mismatches
    && !@summary_rc_file_mismatches
    && !@summary_meta_status_mismatches
    && !@summary_meta_rc_mismatches
    && !@summary_status_rc_mismatches
    && !@meta_status_rc_mismatches;

my $artifact_completeness_pass =
    $counts{run_directories} == $executed_plan_rows
    && $counts{rc_code_files} == $executed_plan_rows
    && $counts{result_meta_files} == $executed_plan_rows
    && $counts{execution_trail_audit_files} == $executed_plan_rows
    && !@run_integrity_issues;

my $execution_expected_path_pass =
    $execution_counts_equal && $execution_relationships_clean;
my $dedup_expected_path_pass =
    $dedup_accounting_pass && $unique_csv_matches_computed;
my $classification_consistency_pass =
    !@summary_meta_status_mismatches
    && !@summary_meta_rc_mismatches
    && !@summary_status_rc_mismatches
    && !@meta_status_rc_mismatches;

my $classification_evidence_pass =
    $classification_consistency_pass
    && !@special_result_evidence_issues;

my $complete_result_files = 0;
my $satisfied_execution_paths = 0;

for my $run_dir (@$run_dirs) {
    my $rc_path    = File::Spec->catfile($run_dir, 'rc.code');
    my $meta_path  = File::Spec->catfile($run_dir, 'result.meta');
    my $audit_path = File::Spec->catfile($run_dir, 'execution_trail.audit');

    my $rc_issues   = file_quality($rc_path, 'rc.code');
    my $meta_issues = file_quality($meta_path, 'result.meta');
    my $audit_text  = read_text($audit_path) // '';

    my $complete =
        !@$rc_issues
        && !@$meta_issues
        && -f $audit_path
        && $audit_text =~ /\S/;

    ++$complete_result_files if $complete;
    ++$satisfied_execution_paths
        if $complete
        && ($summary_path_counter{$run_dir} // 0) == 1
        && !$consistency_issue_runs{$run_dir};
}

my $extra_complete_result_sets =
    max(0, $complete_result_files - $executed_plan_rows);

$complete_result_files =
    min($complete_result_files, $executed_plan_rows);

my $incomplete_result_files =
    max(0, $executed_plan_rows - $complete_result_files);
my $unsatisfied_execution_paths =
    max(0, $executed_plan_rows - $satisfied_execution_paths);

if (!$execution_expected_path_pass && $unsatisfied_execution_paths == 0) {
    $unsatisfied_execution_paths = 1;
    $satisfied_execution_paths = max(0, $executed_plan_rows - 1);
}

my $classification_consistency_failures =
    scalar keys %classification_issue_lines;

$unclassified_count = $classification_consistency_failures;
$classified_count = max(0, scalar(@$summary_rows) - $unclassified_count);

my (@framework_defects, @qualifications);

push @framework_defects,
    'summary.csv does not have the exact approved 17-column schema'
    unless $summary_schema_exact;

push @framework_defects,
    'deduplicated-plan/summary/run-directory/rc.code/result.meta/execution_trail.audit counts differ'
    unless $execution_counts_equal;
push @framework_defects,
    'one-to-one execution relationship or file-integrity checks failed'
    unless $execution_relationships_clean;
push @framework_defects,
    'original = deduplicated + removed duplicate accounting failed'
    unless $dedup_accounting_pass;

if (!defined $unique_csv) {
    push @framework_defects, 'no deduplicated plan CSV was identified';
}
elsif (!$unique_csv_matches_computed) {
    push @framework_defects,
        'deduplicated plan CSV does not match stable exact-row deduplication';
}

if (-f $skipped) {
    push @framework_defects,
        'skipped_dup.csv does not match the recomputed removed rows'
        unless $skipped_csv_matches_computed;
}
else {
    push @qualifications,
        'skipped_dup.csv is absent; removed-duplicate provenance was recomputed but not preserved by the run';
}

push @framework_defects,
    "summary.csv contains $summary_duplicate_extra_rows extra exact duplicate row(s)"
    if $summary_duplicate_extra_rows;
push @framework_defects,
    'the deduplicated plan still contains exact duplicate rows'
    if $unique_duplicate_extra_rows;
push @qualifications,
    scalar(@invalid_timing_rows) . ' summary row(s) have invalid elapsed time'
    if @invalid_timing_rows;
push @qualifications,
    "original plan CSV was read from outside the batch directory: $plan"
    if dirname($plan) ne $batch;
push @qualifications,
    scalar(@failure_rows) . ' non-PASS or nonzero-return-code row(s) require CPAN/module-level interpretation'
    if @failure_rows;
push @framework_defects,
    'summary/result.meta status or status/return-code consistency checks failed'
    unless $classification_consistency_pass;
push @framework_defects,
    scalar(@special_result_evidence_issues)
        . ' special FAIL result(s) lack required note or run-directory evidence'
    if @special_result_evidence_issues;

push @framework_defects,
    "classification evidence did not pass: $classification_detail"
    unless $classification_evidence_pass;

my $final_assessment = @framework_defects ? 'FAIL' : 'PASS';

my @lines;
push @lines,
    'SMOKER BATCH VALIDATION EVIDENCE',
    '=' x 80,
    '',
    "Batch directory: $batch",
    "Generated report: $output",
    'Read-only audit of the batch; only this report file was written.',
    '',
    sprintf("%-28s: %d", 'Original plan tests', $original_plan_rows),
    sprintf("%-28s: %d", 'Unique tests', $executed_plan_rows),
    sprintf("%-28s: %d", 'Duplicate tests skipped', $computed_removed_rows),
    '',
    'SMOKER PERFORMANCE',
    '-' x 80,
    '',
    'Expected execution paths:',
    "  Satisfied:   $satisfied_execution_paths",
    "  Unsatisfied: $unsatisfied_execution_paths",
    '',
    'Required result files:',
    "  Complete:    $complete_result_files",
    "  Incomplete:  $incomplete_result_files",
    '',
    'Result classification:',
    "  Classified:   $classified_count",
    "  Unclassified: $unclassified_count",
    '';

if (@framework_defects) {
    push @lines, 'Framework defects:';
    push @lines, map { "  - $_" } @framework_defects;
    push @lines, '';
}
if (@qualifications) {
    push @lines, 'Notes:';
    push @lines, map { "  - $_" } @qualifications;
    push @lines, '';
}

push @lines,
    'FILES AND DIRECTORIES EXAMINED',
    '-' x 80,
    "Plan CSV: $plan",
    "Summary CSV: $summary",
    'Classification audit: '
        . (-f $classification_report ? $classification_report : '<not present>'),
    "Runs directory: $runs_root",
    'Skipped duplicate CSV: ' . (-f $skipped ? $skipped : '<not present>'),
    'Remaining/unique CSV: ' . (defined $unique_csv ? $unique_csv : '<not identified>'),
    '',
    'EXACT COUNTS',
    '-' x 80;

for my $key (
    qw(
        original_plan_rows
        deduplicated_plan_rows
        computed_unique_rows
        computed_removed_rows
        summary_rows
        run_directories
        rc_code_files
        result_meta_files
        execution_trail_audit_files
    )
) {
    push @lines,
        "$key: " . (defined $counts{$key} ? $counts{$key} : 'N/A');
}
push @lines,
    'skipped_dup.csv data rows: '
        . (-f $skipped ? scalar(@$skipped_rows) : 'NOT PRESENT'),
    '',
    'EXPECTED PATH VERIFICATION',
    '-' x 80,
    'Expected execution path:',
    '  one deduplicated plan row -> one run directory -> one rc.code -> one result.meta -> one execution_trail.audit -> one summary row',
    'Execution count equality: ' . ($execution_counts_equal ? 'PASS' : 'FAIL'),
    'Execution relationship validation: '
        . ($execution_relationships_clean ? 'PASS' : 'FAIL'),
    'Expected execution path result: '
        . ($execution_expected_path_pass ? 'PASS' : 'FAIL'),
    "Classification evidence detail: $classification_detail",
    '',
    'Expected deduplication path:',
    '  original plan rows = deduplicated plan rows + removed duplicate rows',
    "Original plan rows: $original_plan_rows",
    "Recomputed unique rows: $computed_unique_rows",
    "Recomputed removed duplicate rows: $computed_removed_rows",
    'Accounting result: ' . ($dedup_accounting_pass ? 'PASS' : 'FAIL'),
    'Deduplicated CSV matches recomputation: '
        . ($unique_csv_matches_computed ? 'PASS' : 'FAIL');

if (-f $skipped) {
    push @lines,
        'skipped_dup.csv matches recomputation: '
        . ($skipped_csv_matches_computed ? 'PASS' : 'FAIL');
}
else {
    push @lines,
        'skipped_dup.csv matches recomputation: NOT TESTED — file absent';
}

push @lines,
    'Expected deduplication path result: '
        . ($dedup_expected_path_pass ? 'PASS' : 'FAIL'),
    'Summary rows with missing run directories: '
        . scalar(@missing_summary_run_dirs),
    'Summary rows with unresolved/blank run directories: '
        . scalar(@unresolved_summary_run_dirs),
    'Run directories not represented in summary.csv: '
        . scalar(@run_dirs_not_in_summary),
    'Run directories represented more than once: '
        . scalar(@run_dirs_multiple),
    'Extra complete result sets beyond expected executions: '
        . $extra_complete_result_sets,
    'Summary run-directory references repeated: '
        . scalar(keys %summary_duplicate_run_refs),
    '',
    'DEDUPLICATION VERIFICATION',
    '-' x 80,
    "summary.csv exact duplicate groups: $summary_duplicate_groups",
    "summary.csv extra duplicate rows: $summary_duplicate_extra_rows",
    'skipped_dup.csv data rows: '
        . (-f $skipped ? scalar(@$skipped_rows) : 'NOT PRESENT');

if (defined $unique_csv) {
    push @lines,
        "remaining/unique CSV: $unique_csv",
        "remaining/unique CSV exact duplicate groups: $unique_duplicate_groups",
        "remaining/unique CSV extra duplicate rows: $unique_duplicate_extra_rows";
}
else {
    push @lines, 'remaining/unique CSV: not identified';
}

push @lines, '', 'STATUS AND RETURN-CODE ANALYSIS', '-' x 80;
write_counter(\@lines, 'Status counts:', \%status_counter);
write_counter(\@lines, 'Return-code counts:', \%rc_counter);
write_counter(\@lines, 'Status/return-code combinations:', \%status_rc_counter);

if (@special_result_evidence_issues) {
    push @lines, 'Special-result evidence issues:';
    for my $item (@special_result_evidence_issues) {
        my ($line_no, $run_dir, $issues) = @$item;
        push @lines, "  summary line $line_no | $run_dir | " . join('; ', @$issues);
    }
}

push @lines,
    '',
    'INTEGRITY AND COLLISION CHECKS',
    '-' x 80,
    'Run directories with rc.code/result.meta/execution-trail quality issues: '
        . scalar(@run_integrity_issues),
    'rc.code vs result.meta return-code mismatches: '
        . scalar(@rc_meta_mismatches),
    'summary.csv vs rc.code return-code mismatches: '
        . scalar(@summary_rc_file_mismatches),
    'summary.csv vs result.meta status mismatches: '
        . scalar(@summary_meta_status_mismatches),
    'summary.csv vs result.meta return-code mismatches: '
        . scalar(@summary_meta_rc_mismatches),
    'summary.csv status/return-code inconsistencies: '
        . scalar(@summary_status_rc_mismatches),
    'result.meta status/return-code inconsistencies: '
        . scalar(@meta_status_rc_mismatches),
    'Duplicate run-directory basenames: '
        . scalar(keys %duplicate_basenames),
    'Repeated logical test definitions in summary.csv: '
        . scalar(@repeated_logical_tests);

if (@run_integrity_issues) {
    push @lines, 'First 50 run integrity issues:';
    for my $issue (@run_integrity_issues[0 .. min(49, $#run_integrity_issues)]) {
        my ($run_dir, $rc_issues, $meta_issues, $audit_issues) = @$issue;
        push @lines, sprintf(
            '  %s | rc.code=%s | result.meta=%s | execution_trail.audit=%s',
            rel_path($run_dir, $batch),
            @$rc_issues ? join(',', @$rc_issues) : 'OK',
            @$meta_issues ? join(',', @$meta_issues) : 'OK',
            @$audit_issues ? join(',', @$audit_issues) : 'OK',
        );
    }
}

if (@rc_meta_mismatches) {
    push @lines, 'First 50 rc.code/result.meta mismatches:';
    for my $item (@rc_meta_mismatches[0 .. min(49, $#rc_meta_mismatches)]) {
        push @lines,
            sprintf(
                '  %s | rc.code=%s result.meta.rc=%s',
                rel_path($item->[0], $batch),
                $item->[1],
                $item->[2],
            );
    }
}

if (@summary_rc_file_mismatches) {
    push @lines, 'First 50 summary/rc.code mismatches:';
    for my $item (@summary_rc_file_mismatches[0 .. min(49, $#summary_rc_file_mismatches)]) {
        push @lines,
            "  summary line $item->[0] | $item->[1] | summary.rc=$item->[2] rc.code=$item->[3]";
    }
}

if (@summary_meta_status_mismatches) {
    push @lines, 'First 50 summary/result.meta status mismatches:';
    for my $item (
        @summary_meta_status_mismatches[
            0 .. min(49, $#summary_meta_status_mismatches)
        ]
    ) {
        push @lines,
            "  summary line $item->[0] | $item->[1] | "
            . "summary.status=$item->[2] result.meta.status=$item->[3]";
    }
}

if (@summary_meta_rc_mismatches) {
    push @lines, 'First 50 summary/result.meta return-code mismatches:';
    for my $item (
        @summary_meta_rc_mismatches[
            0 .. min(49, $#summary_meta_rc_mismatches)
        ]
    ) {
        push @lines,
            "  summary line $item->[0] | $item->[1] | "
            . "summary.rc=$item->[2] result.meta.rc=$item->[3]";
    }
}

if (@summary_status_rc_mismatches) {
    push @lines, 'First 50 summary status/return-code inconsistencies:';
    for my $item (
        @summary_status_rc_mismatches[
            0 .. min(49, $#summary_status_rc_mismatches)
        ]
    ) {
        push @lines,
            "  summary line $item->[0] | $item->[1] | "
            . "status=$item->[2] rc=$item->[3]";
    }
}

if (@meta_status_rc_mismatches) {
    push @lines, 'First 50 result.meta status/return-code inconsistencies:';
    for my $item (
        @meta_status_rc_mismatches[
            0 .. min(49, $#meta_status_rc_mismatches)
        ]
    ) {
        push @lines,
            "  summary line $item->[0] | $item->[1] | "
            . "result.meta.status=$item->[2] result.meta.rc=$item->[3]";
    }
}

if (@run_dirs_not_in_summary) {
    push @lines, 'First 50 run directories not in summary.csv:';
    for my $path (@run_dirs_not_in_summary[0 .. min(49, $#run_dirs_not_in_summary)]) {
        push @lines, '  ' . rel_path($path, $batch);
    }
}

if (@repeated_logical_tests) {
    push @lines, 'Top 50 repeated logical test definitions:';
    push @lines, '  Identity columns: ' . join(', ', @identity_columns);

    for my $key (@repeated_logical_tests[0 .. min(49, $#repeated_logical_tests)]) {
        my @values = split /\x1E/, $key, -1;
        my @parts;
        for my $i (0 .. $#identity_columns) {
            push @parts, "$identity_columns[$i]=$values[$i]";
        }
        push @lines,
            sprintf('  %8d  %s', $logical_counter{$key}, join(' | ', @parts));
    }
}

push @lines,
    '',
    'TIMING ANALYSIS',
    '-' x 80,
    'Elapsed-time column: ' . ($elapsed_col // '<not found>');

if (%timing_stats) {
    push @lines,
        "Valid timing rows: $timing_stats{count}",
        sprintf('Minimum seconds: %.3f', $timing_stats{min}),
        sprintf('Maximum seconds: %.3f', $timing_stats{max}),
        sprintf('Mean seconds: %.3f', $timing_stats{mean}),
        sprintf('Median seconds: %.3f', $timing_stats{median}),
        sprintf('P90 seconds: %.3f', $timing_stats{p90}),
        sprintf('P95 seconds: %.3f', $timing_stats{p95}),
        sprintf('P99 seconds: %.3f', $timing_stats{p99}),
        sprintf('Unusually slow threshold seconds: %.3f', $slow_threshold),
        'Unusually slow rows listed: ' . scalar(@slow_rows);

    for my $item (@slow_rows) {
        my ($value, $line_no, $row) = @$item;
        my @desc;
        for my $column (qw(base mode module version status rc run_dir)) {
            next unless $summary_field{$column};
            my $field_value = $row->{$column} // '';
            $field_value =~ s/^\s+|\s+$//g;
            push @desc, "$column=$field_value";
        }
        push @lines,
            sprintf(
                '  %12.3fs | summary line %d | %s',
                $value,
                $line_no,
                join(' | ', @desc),
            );
    }
}
else {
    push @lines, 'No valid elapsed-time values found.';
}
push @lines, 'Invalid elapsed-time rows: ' . scalar(@invalid_timing_rows);

push @lines,
    '',
    'FAILURE-PATTERN ANALYSIS',
    '-' x 80,
    'Rows classified for failure analysis: ' . scalar(@failure_rows);

for my $column (@failure_group_columns) {
    write_counter(
        \@lines,
        "Failures by $column:",
        $failure_groups{$column},
        50,
    );
}

write_counter(
    \@lines,
    'Failures by first dependency and version:',
    $dep_one_version_failures,
    50,
);
write_counter(
    \@lines,
    'Failures by second dependency and version:',
    $dep_two_version_failures,
    50,
);

push @lines,
    '',
    'Interpretation boundary:',
    '  This evidence file identifies structural/framework defects separately from non-PASS CPAN/module outcomes.',
    '  It does not infer that every non-PASS result is a framework defect.',
    '  Detailed build.log/run.err review is required for causal classification of module-specific failures.',
    '',
    'RISKS AND LIMITATIONS',
    '-' x 80,
    '1. The plan CSV is auto-discovered. Confirm that the reported plan path is the exact plan used for this batch.',
    '2. Logical repetition is reported as a heuristic and is not automatically classified as corruption.',
    '3. result.meta checks validate key=value structure, required status and rc keys, and cross-file status/return-code consistency.',
    '4. Framework-versus-CPAN causal classification requires inspection of logs for the non-PASS subset.',
    '',
    'FINAL ASSESSMENT',
    '-' x 80,
    "Assessment: $final_assessment",
    '';

if (@framework_defects) {
    push @lines,
        'Reason: one or more structural, consistency, or deduplication defects were detected.';
}
else {
    push @lines,
        'Reason: the expected execution and deduplication paths passed. Recorded notes do not constitute structural failures.';
}

push @lines,
    '',
    'REPRODUCIBILITY',
    '-' x 80,
    'Command used:',
    "  " . basename($0) . " \\",
    "    $batch \\",
    "    $output",
    '',
    "CSV files were parsed with Perl's Text::CSV module.",
    '';

write_text($output, join("\n", @lines) . "\n");

print "Report written: $output\n";
print "\n";
printf "%-28s: %d\n", 'Original plan tests', $original_plan_rows;
printf "%-28s: %d\n", 'Unique tests', $executed_plan_rows;
printf "%-28s: %d\n", 'Duplicate tests skipped', $computed_removed_rows;
print "\n";
print "Smoker Performance\n";
print "\n";
print "Expected execution paths:\n";
print "  Satisfied:   $satisfied_execution_paths\n";
print "  Unsatisfied: $unsatisfied_execution_paths\n";
print "\n";
print "Required result files:\n";
print "  Complete:    $complete_result_files\n";
print "  Incomplete:  $incomplete_result_files\n";
print "\n";
print "Result classification:\n";
print "  Classified:   $classified_count\n";
print "  Unclassified: $unclassified_count\n";

print "\n";
my @st = stat($output);
my $size = $st[7] // 0;
printf "%s %d bytes\n", $output, $size;

open my $line_fh, '<:encoding(UTF-8)', $output
    or die_error("cannot reopen $output: $!");
my $line_count = 0;
++$line_count while <$line_fh>;
close $line_fh;
print "$line_count $output\n";
print "REPORT COMPLETE\n";

# Exit status is part of the validator interface:
#   0 = structural integrity passed
#   1 = one or more integrity defects were detected
#   2 = validator usage/input/internal error (used by earlier error paths)
exit($final_assessment eq 'PASS' ? 0 : 1);
