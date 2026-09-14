#!/usr/bin/env perl
use strict;
use warnings;
use File::Path qw(make_path);
use File::Spec;
use Text::CSV;

my ($original_path, $replacement_path, $output_dir, @additional_replacement_paths) = @ARGV;
die "usage: $0 ORIGINAL_SUMMARY REPLACEMENT_SUMMARY OUTPUT_DIR [ADDITIONAL_REPLACEMENT_SUMMARY ...]\n"
    unless defined $output_dir;
my @replacement_paths = ($replacement_path, @additional_replacement_paths);
my @key_fields = qw(base mode module version dep_one dep_one_version dep_two dep_two_version);
my @provenance_fields = qw(classification_source_batch classification_source_run_id supersedes_status supersedes_rc supersedes_note supersedes_run_dir);

sub open_reader {
    my ($path) = @_;
    open my $fh, '<', $path or die "cannot read $path: $!\n";
    my $csv = Text::CSV->new({ binary => 1, auto_diag => 1 });
    my $header = $csv->getline($fh) or die "missing CSV header in $path\n";
    $csv->column_names(@{$header});
    return ($fh, $csv, $header);
}

sub logical_key {
    my ($row) = @_;
    return join '', map {
        my $value = defined $row->{$_} ? $row->{$_} : '';
        length($value) . ':' . $value;
    } @key_fields;
}

my %replacement_by_key;
my $replacement_header;
my ($replacement_input_rows, $superseded_replacement_rows) = (0, 0);
for my $path (@replacement_paths) {
    my ($replacement_fh, $replacement_csv, $header) = open_reader($path);
    $replacement_header //= $header;
    die "replacement summary schemas differ\n"
        unless join("\0", @{$replacement_header}) eq join("\0", @{$header});
    while (my $row = $replacement_csv->getline_hr($replacement_fh)) {
        ++$replacement_input_rows;
        my $key = logical_key($row);
        ++$superseded_replacement_rows if exists $replacement_by_key{$key};
        # Replacement summaries are supplied oldest to newest.  A later exact
        # rerun supersedes an earlier diagnostic for the same logical row.
        $replacement_by_key{$key} = $row;
    }
    close $replacement_fh or die "cannot close $path: $!\n";
}
my $replacement_rows = scalar keys %replacement_by_key;
die "replacement summary has no data rows\n" unless $replacement_rows;

my ($original_fh, $original_csv, $original_header) = open_reader($original_path);
die "source summary schemas differ\n" unless join("\0", @{$original_header}) eq join("\0", @{$replacement_header});
make_path($output_dir) unless -d $output_dir;
my $output_path = File::Spec->catfile($output_dir, 'summary_reconciled.csv');
my $evidence_path = File::Spec->catfile($output_dir, 'reconciliation_evidence.txt');
open my $output_fh, '>', $output_path or die "cannot write $output_path: $!\n";
my $writer = Text::CSV->new({ binary => 1, eol => "\n", auto_diag => 1 });
$writer->print($output_fh, [ @{$original_header}, @provenance_fields ]);

my ($original_rows, $substituted_rows) = (0, 0);
my (%status_counts, %rc_counts, %transition_counts);
while (my $original = $original_csv->getline_hr($original_fh)) {
    ++$original_rows;
    my $replacement = delete $replacement_by_key{logical_key($original)};
    my ($chosen, @provenance);
    if ($replacement) {
        ++$substituted_rows;
        $chosen = $replacement;
        @provenance = ($replacement->{batch}, $replacement->{run_id}, $original->{status}, $original->{rc}, $original->{note}, $original->{run_dir});
        ++$transition_counts{"$original->{status},rc=$original->{rc} -> $replacement->{status},rc=$replacement->{rc}"};
    } else {
        $chosen = $original;
        @provenance = ($original->{batch}, $original->{run_id}, '', '', '', '');
    }
    ++$status_counts{$chosen->{status}};
    ++$rc_counts{$chosen->{rc}};
    $writer->print(
        $output_fh,
        [ (map { $chosen->{$_} } @{$original_header}), @provenance ],
    );
}
close $original_fh or die "cannot close $original_path: $!\n";
close $output_fh or die "cannot close $output_path: $!\n";
die scalar(keys %replacement_by_key) . " replacement row(s) did not match the original summary\n" if %replacement_by_key;
die "matched $substituted_rows replacement rows, expected $replacement_rows\n" unless $substituted_rows == $replacement_rows;

open my $evidence_fh, '>', $evidence_path or die "cannot write $evidence_path: $!\n";
print {$evidence_fh} "SMOKER SUMMARY RECONCILIATION EVIDENCE\n", "=" x 80, "\n\n";
print {$evidence_fh} "Original summary: $original_path\n";
print {$evidence_fh} "Replacement summary: $_\n" for @replacement_paths;
print {$evidence_fh} "Reconciled summary: $output_path\n\n";
print {$evidence_fh} "Original rows: $original_rows\nReplacement input rows: $replacement_input_rows\nSuperseded replacement rows: $superseded_replacement_rows\nUnique replacement rows: $replacement_rows\nMatched substitutions: $substituted_rows\nUnmatched replacement rows: 0\nReconciled rows: $original_rows\n\n";
print {$evidence_fh} "STATUS COUNTS\n";
print {$evidence_fh} "$_=$status_counts{$_}\n" for sort keys %status_counts;
print {$evidence_fh} "\nRETURN-CODE COUNTS\n";
print {$evidence_fh} "rc_$_=$rc_counts{$_}\n" for sort { $a <=> $b } keys %rc_counts;
print {$evidence_fh} "\nSUBSTITUTION TRANSITIONS\n";
print {$evidence_fh} "$_=$transition_counts{$_}\n" for sort keys %transition_counts;
print {$evidence_fh} "\nASSESSMENT\nPASS\nAll unique replacement logical rows matched exactly once. For overlapping replacement evidence, the newest supplied summary was selected. The original and replacement summaries were read-only inputs.\n";
close $evidence_fh or die "cannot close $evidence_path: $!\n";
print "wrote $output_path\nwrote $evidence_path\n";
