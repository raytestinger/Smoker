#!/usr/bin/env perl
use strict;
use warnings;

use Getopt::Long qw(GetOptions);
use FindBin qw($Bin);
use JSON::PP ();
use lib "$Bin/../lib";
use Smoker::PlanCSV qw(canonical_row_key read_csv_file);

my $input;
my $output;
my $json_output;
my $help;

GetOptions(
    'input=s'       => \$input,
    'output=s'      => \$output,
    'json-output=s' => \$json_output,
    'help'          => \$help,
) or die usage();

die usage() if $help;
die "--input is required\n"  unless defined $input  && length $input;
die "--output is required\n" unless defined $output && length $output;

my @schema = qw(
    base mode module version
    dep_one dep_one_version dep_two dep_two_version
);

my ($header, $plan_rows) = read_csv_file(
    path            => $input,
    expected_header => \@schema,
    reject_blank    => 1,
);

my $rows = 0;
my $duplicate_rows = 0;

my (%seen_row, %by_mode, %by_base, %by_module, %dependency_frequency);
my (%module_versions, %dependency_versions);

for my $fields (@$plan_rows) {
    my %row;
    @row{@schema} = @$fields;

    $rows++;

    my $key = canonical_row_key($fields);
    $duplicate_rows++ if $seen_row{$key}++;

    $by_mode{$row{mode}}++;
    $by_base{$row{base}}++;
    $by_module{$row{module}}++;

    $module_versions{$row{module}}{$row{version}} = 1
        if $row{version} ne '';

    if ($row{dep_one} ne '') {
        $dependency_frequency{$row{dep_one}}++;
        $dependency_versions{$row{dep_one}}{$row{dep_one_version}} = 1
            if $row{dep_one_version} ne '';
    }

    if ($row{dep_two} ne '') {
        $dependency_frequency{$row{dep_two}}++;
        $dependency_versions{$row{dep_two}}{$row{dep_two_version}} = 1
            if $row{dep_two_version} ne '';
    }
}

my $unique_rows = scalar keys %seen_row;

my %analysis = (
    schema_version       => 1,
    input                => $input,
    rows                 => $rows,
    unique_rows          => $unique_rows,
    duplicate_rows       => $duplicate_rows,
    unique_bases         => scalar(keys %by_base),
    unique_modules       => scalar(keys %by_module),
    unique_dependencies  => scalar(keys %dependency_frequency),
    rows_by_mode         => \%by_mode,
    rows_by_base         => \%by_base,
    rows_by_module       => \%by_module,
    dependency_frequency => \%dependency_frequency,
    module_version_counts => {
        map {
            $_ => scalar(keys %{ $module_versions{$_} })
        } keys %module_versions
    },
    dependency_version_counts => {
        map {
            $_ => scalar(keys %{ $dependency_versions{$_} })
        } keys %dependency_versions
    },
);

open my $report, '>', $output or die "open $output: $!\n";

print {$report} "Smoker plan analysis\n";
print {$report} "====================\n\n";
print {$report} "Input:                $input\n";
print {$report} "Rows:                 $rows\n";
print {$report} "Unique rows:          $unique_rows\n";
print {$report} "Duplicate rows:       $duplicate_rows\n";
print {$report} "Unique Perl bases:    ", scalar(keys %by_base), "\n";
print {$report} "Unique modules:       ", scalar(keys %by_module), "\n";
print {$report} "Unique dependencies:  ", scalar(keys %dependency_frequency), "\n";

print {$report} "\nRows by mode\n";
print {$report} "------------\n";
for my $name (sort keys %by_mode) {
    printf {$report} "%-20s %d\n", $name, $by_mode{$name};
}

print {$report} "\nRows by Perl base\n";
print {$report} "-----------------\n";
for my $name (sort keys %by_base) {
    printf {$report} "%-20s %d\n", $name, $by_base{$name};
}

print {$report} "\nRows by target module\n";
print {$report} "---------------------\n";
for my $name (
    sort {
        $by_module{$b} <=> $by_module{$a}
            || $a cmp $b
    } keys %by_module
) {
    printf {$report} "%-50s %d\n", $name, $by_module{$name};
}

print {$report} "\nDependency frequency\n";
print {$report} "--------------------\n";
for my $name (
    sort {
        $dependency_frequency{$b} <=> $dependency_frequency{$a}
            || $a cmp $b
    } keys %dependency_frequency
) {
    printf {$report} "%-50s %d\n",
        $name, $dependency_frequency{$name};
}

close $report or die "close $output: $!\n";

if (defined $json_output && length $json_output) {
    open my $json, '>', $json_output or die "open $json_output: $!\n";
    print {$json} JSON::PP->new->ascii->canonical->pretty->encode(\%analysis);
    close $json or die "close $json_output: $!\n";
}

print "Rows analyzed:         $rows\n";
print "Unique rows:           $unique_rows\n";
print "Duplicate rows:        $duplicate_rows\n";
print "Unique Perl bases:     ", scalar(keys %by_base), "\n";
print "Unique modules:        ", scalar(keys %by_module), "\n";
print "Unique dependencies:   ", scalar(keys %dependency_frequency), "\n";
print "Report:                $output\n";
print "JSON report:           $json_output\n"
    if defined $json_output && length $json_output;

exit 0;

sub usage {
    return <<'USAGE';
Usage:
  plan_analyze.pl --input plan.csv --output plan.analysis.txt [options]

Options:
  --input FILE
      Source eight-column Smoker plan CSV.

  --output FILE
      Human-readable analysis report.

  --json-output FILE
      Optional machine-readable JSON analysis.

  --help
      Show this help.

The report includes:
  * total, unique, and duplicate row counts
  * row counts by mode and Perl base
  * target-module frequencies
  * dependency frequencies
  * unique target and dependency counts
USAGE
}
