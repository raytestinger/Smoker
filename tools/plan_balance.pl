#!/usr/bin/env perl
use strict;
use warnings;

use Getopt::Long qw(GetOptions);
use FindBin qw($Bin);
use File::Basename qw(dirname basename);
use File::Spec;
use List::Util qw(shuffle);
use lib "$Bin/../lib";
use Smoker::PlanCSV qw(canonical_row_key read_csv_file write_csv_row);

my $input;
my $output;
my $target_rows = 0;
my $seed = 20260724;
my $help;

GetOptions(
    'input=s'       => \$input,
    'output=s'      => \$output,
    'target-rows=i' => \$target_rows,
    'seed=i'        => \$seed,
    'help'          => \$help,
) or die usage();

die usage() if $help;
die "--input is required\n"  unless defined $input  && length $input;
die "--output is required\n" unless defined $output && length $output;
die "--target-rows must be >= 0\n" if $target_rows < 0;
die "--input and --output must be different files\n"
    if File::Spec->rel2abs($input) eq File::Spec->rel2abs($output);

my @schema = qw(
    base mode module version
    dep_one dep_one_version dep_two dep_two_version
);

my ($header, $plan_rows) = read_csv_file(
    path            => $input,
    expected_header => \@schema,
    reject_blank    => 1,
);

my @rows;
my %seen;
my $record_number = 1;

for my $fields (@$plan_rows) {
    $record_number++;

    my %row;
    @row{@schema} = @$fields;

    my $key = canonical_row_key($fields);
    die "duplicate execution row at input record $record_number\n"
        if $seen{$key}++;

    push @rows, \%row;
}

die "requested $target_rows rows, but input contains only "
    . scalar(@rows) . "\n"
    if $target_rows && $target_rows > @rows;

srand($seed);

my %bucket;
for my $row (@rows) {
    my $bucket_key = join "\x1f",
        $row->{mode},
        $row->{base},
        $row->{module};

    push @{ $bucket{$bucket_key} }, $row;
}

for my $key (keys %bucket) {
    @{ $bucket{$key} } = shuffle(@{ $bucket{$key} });
}

my @bucket_keys = shuffle(sort keys %bucket);
my @balanced;
my $wanted = $target_rows || scalar(@rows);

while (@balanced < $wanted) {
    my $progress = 0;

    for my $key (@bucket_keys) {
        next unless @{ $bucket{$key} };

        push @balanced, shift @{ $bucket{$key} };
        $progress = 1;

        last if @balanced >= $wanted;
    }

    last unless $progress;
}

die "internal error: selected " . scalar(@balanced)
    . " rows, expected $wanted\n"
    unless @balanced == $wanted;

my ($tmp_path, $out) = open_temp_output($output);

write_csv_row($out, \@schema);

for my $row (@balanced) {
    write_csv_row($out, [@{$row}{@schema}]);
}

close $out or die "close $tmp_path: $!\n";
rename $tmp_path, $output
    or die "rename $tmp_path to $output: $!\n";

print "Input rows:          ", scalar(@rows), "\n";
print "Balance buckets:     ", scalar(keys %bucket), "\n";
print "Rows written:        ", scalar(@balanced), "\n";
print "Rows omitted by cap: ", scalar(@rows) - scalar(@balanced), "\n";
print "Seed:                $seed\n";
print "Output:              $output\n";

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
  plan_balance.pl --input plan.unique.csv --output plan.balanced.csv [options]

Options:
  --input FILE
      Source eight-column Smoker plan CSV. Input rows must already be unique.

  --output FILE
      Destination CSV in balanced round-robin order.

  --target-rows N
      Optional balanced subset size. Zero writes all rows.
      Default: 0.

  --seed N
      Random seed controlling bucket and within-bucket order.
      Default: 20260724.

  --help
      Show this help.

Balancing:
  Rows are placed into buckets keyed by:
      mode + Perl base + target module

  Output is selected round-robin across those buckets. This spreads modes,
  Perl images, and target modules through the plan instead of leaving long
  runs of similar rows.
USAGE
}
