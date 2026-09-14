#!/usr/bin/env perl
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Smoker::AuditIO qw(options read_csv write_csv write_text new_output
    tuple prerequisite plan_fields ranked_counts);

my $args = options(qw(input-overlay output));
my ($all) = read_csv($args->{'input-overlay'});
my @rows = grep { $_->{historical_taxonomy} eq 'missing_prerequisite' } @$all;
die "expected 1,037 missing-prerequisite rows\n" unless @rows == 1037;
my (%groups, @order);
for my $row (@rows) {
    my $mechanism = prerequisite($row->{note});
    push @order, $mechanism unless exists $groups{$mechanism};
    push @{ $groups{$mechanism} }, $row;
}
die "expected 12 prerequisite mechanisms\n" unless keys(%groups) == 12;
my $outdir = $args->{output}; new_output($outdir);
my %counts = map { $_ => scalar @{ $groups{$_} } } keys %groups;
my @inventory;
for my $mechanism (ranked_counts(\%counts, \@order, 1)) {
    my (%pairs, %bases);
    for my $row (@{ $groups{$mechanism} }) {
        $pairs{tuple($row->{module}, $row->{version})} = 1;
        $bases{$row->{base}} = 1;
    }
    push @inventory, [$mechanism, $counts{$mechanism}, scalar(keys %pairs), scalar(keys %bases)];
}
write_csv("$outdir/missing_prerequisite_inventory.csv",
    [qw(missing_prerequisite historical_rows target_pairs perl_bases)], \@inventory);
my %rank = (baseline => 0, 'vary-one' => 1, 'vary-two' => 2);
my @bases = map { "perl:5.$_" } (34, 36, 38, 40, 42);
my @selected;
for my $mechanism (sort keys %groups) {
    my %by_base;
    for my $row (@{ $groups{$mechanism} }) { push @{ $by_base{$row->{base}} }, $row; }
    die "incomplete base coverage: $mechanism\n"
        unless join('\0', sort keys %by_base) eq join('\0', @bases);
    for my $base (sort keys %by_base) {
        for my $row (@{ $by_base{$base} }) { die "unknown mode: $row->{mode}\n" unless exists $rank{$row->{mode}}; }
        # The final tie remains in input order, like Python min().
        my @candidates = sort {
            $rank{$a->{mode}} <=> $rank{$b->{mode}}
                || (length($a->{dep_two}) > 0) <=> (length($b->{dep_two}) > 0)
                || $a->{run_id} cmp $b->{run_id}
        } @{ $by_base{$base} };
        push @selected, [$mechanism, $candidates[0]];
    }
}
my @fields = plan_fields();
my $plan = "$outdir/60_missing_prerequisite_exact_confirmation.csv";
write_csv($plan, \@fields, [map { [@{ $_->[1] }{@fields}] } @selected]);
my $sources = "$outdir/60_missing_prerequisite_exact_confirmation_sources.csv";
write_csv($sources, ['missing_prerequisite', 'historical_run_id', @fields, 'historical_note'],
    [map { my ($mechanism, $row) = @$_; [$mechanism, $row->{run_id}, @$row{@fields}, $row->{note}] } @selected]);
my @lines = ('Smoker missing-prerequisite frontier', '====================================', '',
    'Historical rows: 1037', 'Distinct prerequisite mechanisms: 12',
    'Exact confirmation rows selected: 60',
    'Selection: one simplest exact historical plan identity per prerequisite and Perl base.', '',
    (map { sprintf('%4d  %s', $counts{$_}, $_) } ranked_counts(\%counts, \@order)),
    '', $plan, $sources);
my $report = "$outdir/missing_prerequisite_frontier.txt";
write_text($report, join("\n", @lines) . "\n"); print "$report\n";
