#!/usr/bin/env perl
use strict;
use warnings;

use Getopt::Long qw(GetOptions);
use FindBin qw($Bin);
use File::Basename qw(dirname basename);
use File::Spec;
use lib "$Bin/../lib";
use Smoker::PlanCSV qw(deduplicate_csv);

my $input;
my $output;
my $duplicates_output;
my $help;
my $verbose = 1;

GetOptions(
    'input=s'             => \$input,
    'output=s'            => \$output,
    'duplicates-output=s' => \$duplicates_output,
    'verbose!'            => \$verbose,
    'help'                => \$help,
) or die usage();

die usage() if $help;
die "--input is required\n"  unless defined $input  && length $input;
die "--output is required\n" unless defined $output && length $output;
die "--input and --output must be different files\n"
    if File::Spec->rel2abs($input) eq File::Spec->rel2abs($output);

if (defined $duplicates_output && length $duplicates_output) {
    die "--duplicates-output must differ from --input\n"
        if File::Spec->rel2abs($duplicates_output) eq File::Spec->rel2abs($input);
    die "--duplicates-output must differ from --output\n"
        if File::Spec->rel2abs($duplicates_output) eq File::Spec->rel2abs($output);
}

my @schema = qw(
    base mode module version
    dep_one dep_one_version dep_two dep_two_version
);

my ($out_tmp, $out_fh) = open_temp_output($output);
close $out_fh or die "close $out_tmp: $!\n";

my ($dup_tmp, $dup_fh);
if (defined $duplicates_output && length $duplicates_output) {
    ($dup_tmp, $dup_fh) = open_temp_output($duplicates_output);
    close $dup_fh or die "close $dup_tmp: $!\n";
}

my ($input_rows, $unique_rows, $duplicate_rows) = deduplicate_csv(
    source_path     => $input,
    output_path     => $out_tmp,
    duplicates_path => $dup_tmp,
    expected_header => \@schema,
    reject_blank    => 1,
);

rename $out_tmp, $output
    or die "rename $out_tmp to $output: $!\n";

if (defined $dup_tmp) {
    rename $dup_tmp, $duplicates_output
        or die "rename $dup_tmp to $duplicates_output: $!\n";
}

print "Input rows:           $input_rows\n";
print "Unique rows written:  $unique_rows\n";
print "Duplicate rows:       $duplicate_rows\n";
print "Output:               $output\n";
print "Duplicates output:    $duplicates_output\n"
    if defined $duplicates_output && length $duplicates_output;

exit 0;

sub open_temp_output {
    my ($path) = @_;

    my $dir  = dirname($path);
    my $base = basename($path);
    die "output directory does not exist: $dir\n" unless -d $dir;

    my $tmp = File::Spec->catfile(
        $dir,
        ".$base.tmp.$$",
    );

    open my $fh, '>', $tmp or die "open $tmp: $!\n";
    return ($tmp, $fh);
}

sub usage {
    return <<'USAGE';
Usage:
  plan_dedup.pl --input plan.raw.csv --output plan.unique.csv [options]

Options:
  --input FILE
      Source eight-column Smoker plan CSV.

  --output FILE
      Destination containing the first occurrence of each unique execution row.

  --duplicates-output FILE
      Optional CSV containing rows removed as duplicates.

  --[no-]verbose
      Print periodic progress. Enabled by default.

  --help
      Show this help.

Behavior:
  * preserves the input order of first occurrences
  * validates the exact eight-column Smoker plan schema
  * compares duplicate identity using all ordered parsed CSV fields
  * writes output through a temporary file and renames it on success
USAGE
}
