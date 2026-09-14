#!/usr/bin/env perl

use strict;
use warnings;
use Text::CSV_XS;

my $summary = shift @ARGV
    or die "usage: $0 test_results/<batch>/summary.csv\n";

open my $fh, '<', $summary
    or die "cannot open $summary: $!\n";

my $csv = Text::CSV_XS->new({
    binary   => 1,
    auto_diag => 1,
});

my $header = $csv->getline($fh)
    or die "empty CSV: $summary\n";

$csv->column_names(@$header);

my %by_module;

while (my $row = $csv->getline_hr($fh)) {
    my $module = $row->{module} // '';
    next if $module eq '';

    push @{ $by_module{$module} }, $row;
}

close $fh;

print join(",",
    qw(
      module
      baseline_base
      baseline_status
      fail_base
      fail_mode
      dep_one
      dep_one_version
      dep_two
      dep_two_version
      rc
      elapsed_s
      run_dir
    )
), "\n";

for my $module (sort keys %by_module) {
    my @rows = @{ $by_module{$module} };

    my @baseline_pass = grep {
        ($_->{mode} // '') eq 'baseline'
        && ($_->{status} // '') eq 'PASS'
    } @rows;

    next unless @baseline_pass;

    my @perturbed_fail = grep {
        ($_->{mode} // '') ne 'baseline'
        && ($_->{status} // '') eq 'FAIL'
    } @rows;

    next unless @perturbed_fail;

    for my $base_row (@baseline_pass) {
        for my $fail_row (@perturbed_fail) {
            print_csv_row(
                $module,
                $base_row->{base}   // '',
                $base_row->{status} // '',
                $fail_row->{base}   // '',
                $fail_row->{mode}   // '',
                $fail_row->{dep_one} // '',
                $fail_row->{dep_one_version} // '',
                $fail_row->{dep_two} // '',
                $fail_row->{dep_two_version} // '',
                $fail_row->{rc} // '',
                $fail_row->{elapsed_s} // '',
                $fail_row->{run_dir} // '',
            );
        }
    }
}

sub print_csv_row {
    my @fields = @_;

    my $out = Text::CSV_XS->new({
        binary => 1,
        eol    => "\n",
    });

    $out->print(*STDOUT, \@fields);
}