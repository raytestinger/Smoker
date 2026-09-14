#!/usr/bin/env perl
use strict;
use warnings;

use Getopt::Long qw(GetOptions);
use FindBin qw($Bin);
use File::Basename qw(dirname basename);
use File::Spec;
use List::Util qw(shuffle);
use lib "$Bin/../lib";
use Smoker::PlanCSV qw(read_csv_file write_csv_row);

my $input;
my $output;
my $seed = time;
my $help;

GetOptions(
    'input=s'  => \$input,
    'output=s' => \$output,
    'seed=i'   => \$seed,
    'help'     => \$help,
) or die usage();

die usage() if $help;
die "--input is required\n"  unless defined $input  && length $input;
die "--output is required\n" unless defined $output && length $output;
die "--input and --output must be different files\n"
    if File::Spec->rel2abs($input) eq File::Spec->rel2abs($output);

my @schema = qw(
    base mode module version
    dep_one dep_one_version dep_two dep_two_version
);

my ($header, $rows) = read_csv_file(
    path            => $input,
    expected_header => \@schema,
    reject_blank    => 1,
);

srand($seed);
my @rows = shuffle(@$rows);

my ($tmp_path, $out) = open_temp_output($output);

write_csv_row($out, \@schema);

for my $row (@rows) {
    write_csv_row($out, $row);
}

close $out or die "close $tmp_path: $!\n";
rename $tmp_path, $output
    or die "rename $tmp_path to $output: $!\n";

print "Input rows:     ", scalar(@rows), "\n";
print "Rows shuffled:  ", scalar(@rows), "\n";
print "Seed:           $seed\n";
print "Output:         $output\n";

exit 0;

sub open_temp_output {
    my ($path) = @_;

    my $dir  = dirname($path);
    my $base = basename($path);
    die "output directory does not exist: $dir\n" unless -d $dir;

    my $tmp = File::Spec->catfile($dir, ".$base.tmp.$$");
    open my $fh, '>', $tmp or die "open $tmp: $!\n";

    return ($tmp, $fh);
}

sub usage {
    return <<'USAGE';
Usage:
  plan_shuffle.pl --input plan.unique.csv --output plan.shuffled.csv [options]

Options:
  --input FILE
      Source eight-column Smoker plan CSV.

  --output FILE
      Destination CSV containing the same rows in shuffled order.

  --seed N
      Random seed. Supplying the same seed and input reproduces the same order.
      Default: current Unix time.

  --help
      Show this help.

Behavior:
  * preserves the exact eight-column Smoker plan schema
  * validates every input row
  * preserves all rows without adding or removing any
  * writes through a temporary file and renames it on success
USAGE
}
