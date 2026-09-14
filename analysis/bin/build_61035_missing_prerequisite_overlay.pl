#!/usr/bin/env perl
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Smoker::AuditIO qw(options read_csv write_csv write_text new_output
    require_evidence tuple prerequisite plan_fields report_counts);

my $args = options(qw(input-overlay batch sources output));
require_evidence($args->{batch});
my @keys = plan_fields();
my ($sources) = read_csv($args->{sources});
my %mapping = map { tuple(@{$_}{@keys}) => $_->{missing_prerequisite} } @$sources;
my ($confirmation) = read_csv("$args->{batch}/summary.csv");
my %groups;
for my $row (@$confirmation) {
    my $key = tuple(@$row{@keys});
    die "confirmation row has no source mapping\n" unless exists $mapping{$key};
    push @{ $groups{$mapping{$key}} }, $row;
}
die "expected 12 five-base groups\n"
    if keys(%groups) != 12 || grep { @$_ != 5 } values %groups;
for my $mechanism (keys %groups) {
    for my $row (@{ $groups{$mechanism} }) {
        die "mechanism did not reproduce cleanly: $mechanism\n"
            unless $row->{status} eq 'FAIL' && $row->{rc} eq '1'
            && $row->{note} =~ /Missing prerequisite: (.+?)(?:;|$)/ && $1 eq $mechanism;
    }
}
my ($rows, $fields) = read_csv($args->{'input-overlay'});
my $count = 0;
for my $row (@$rows) {
    next unless $row->{historical_taxonomy} eq 'missing_prerequisite';
    my $mechanism = prerequisite($row->{note});
    die "unconfirmed prerequisite: $mechanism\n" unless exists $groups{$mechanism};
    $row->{audit_evidence} = 'missing_prerequisite_mechanism_reproduced_all_bases';
    ++$count;
}
die "historical accounting changed\n" unless @$rows == 61035 && $count == 1037;
my $outdir = $args->{output}; new_output($outdir);
my $overlay = "$outdir/61035_failure_audit_post_prerequisite_overlay.csv";
write_csv($overlay, $fields, $rows);
my @lines = ('Smoker post-prerequisite evidence overlay',
    '=========================================', '', report_counts($rows, 'audit_evidence', 6), '',
    'PASS: 1,037 rows assigned from 12 mechanisms reproduced across all five bases.', $overlay);
my $report = "$outdir/61035_failure_audit_post_prerequisite_overlay.txt";
write_text($report, join("\n", @lines) . "\n"); print "$report\n";
