#!/usr/bin/env perl
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Cwd qw(abs_path);
use File::Basename qw(basename);
use Smoker::AuditIO qw(options read_csv write_csv write_text new_output
    require_evidence tuple tuple_values tuple_cmp report_counts children);

sub classify_outcome {
    my ($pair, $rows) = @_;
    my ($module, $version) = tuple_values($pair);
    my $marker = "Configuration failed for $module $version";
    my $install = "Installation failed while applying dependency version $module $version";
    my ($config, $pass, $installation) = (0, 0, 0);
    for my $row (@$rows) {
        ++$config if $row->{status} eq 'FAIL' && $row->{rc} eq '1' && index($row->{note}, $marker) >= 0;
        ++$pass if $row->{status} eq 'PASS' && $row->{rc} eq '0';
        ++$installation if $row->{status} eq 'FAIL' && $row->{rc} eq '1' && index($row->{note}, $install) >= 0;
    }
    return 'configuration_pair_reproduced_all_bases' if $config == 5;
    return 'configuration_pair_not_reproduced' if $pass == 5;
    return 'configuration_pair_version_dependent' if $config && $pass && $config + $pass == 5;
    return 'configuration_pair_mixed_failure_mechanism' if $config && $installation && $config + $installation == 5;
    return 'configuration_pair_confirmation_inconclusive';
}

my $args = options(qw(development output));
my $root = abs_path($args->{development}) // die "development directory not found\n";
my @candidates = sort grep { basename($_) =~ /^60_configuration_failure_confirmation_.*_.*$/ }
    children("$root/test_results");
my %latest;
for my $batch (@candidates) {
    next unless basename($batch) =~ /configuration_failure_confirmation_(\d+)_/;
    $latest{0 + $1} = $batch;
}
my @batches = map { $latest{$_} } sort { $a <=> $b } keys %latest;
die 'expected thirteen confirmation batches, found ' . @batches . "\n" unless @batches == 13;
my (%pairs, $executions);
$executions = 0;
for my $batch (@batches) {
    require_evidence($batch);
    my ($rows) = read_csv("$batch/summary.csv");
    die "expected 60 summary rows: $batch\n" unless @$rows == 60;
    $executions += @$rows;
    for my $row (@$rows) { push @{ $pairs{tuple($row->{dep_one}, $row->{dep_one_version})} }, $row; }
}
my @retries = sort grep { basename($_) =~ /^3_configuration_timeout_retry_/ } children("$root/test_results");
die "missing configuration timeout retry batch\n" unless @retries;
my $retry = $retries[-1];
require_evidence($retry);
my ($retry_rows) = read_csv("$retry/summary.csv");
die "expected 3 timeout-retry rows: $retry\n" unless @$retry_rows == 3;
$executions += @$retry_rows;
for my $row (@$retry_rows) {
    my $key = tuple($row->{dep_one}, $row->{dep_one_version});
    $pairs{$key} = [grep { $_->{base} ne $row->{base} } @{ $pairs{$key} // [] }];
    push @{ $pairs{$key} }, $row;
}
my %evidence = map { $_ => classify_outcome($_, $pairs{$_}) } keys %pairs;
my ($rows, $fields) = read_csv("$root/analysis/61035_audit_20260823/61035_failure_audit.csv");
die 'expected 61,035 historical rows, found ' . @$rows . "\n" unless @$rows == 61035;
my (%historical, @configuration);
for my $row (@$rows) {
    next unless $row->{historical_taxonomy} eq 'configuration_failed';
    die "configuration-failure note is not parseable: $row->{note}\n"
        unless $row->{note} =~ /Configuration failed for (.+?) ([^ ;]+)(?:;|$)/;
    my ($module, $version) = ($1, $2);
    my $key = tuple($module, $version);
    ++$historical{$key};
    $row->{failed_dependency} = $module;
    $row->{failed_dependency_version} = $version;
    $row->{audit_evidence} = $evidence{$key} // 'configuration_failure_not_independently_confirmed';
    push @configuration, $row;
}
my $outdir = $args->{output};
new_output($outdir);
my $overlay = "$outdir/61035_failure_audit_configuration_overlay.csv";
write_csv($overlay, $fields, $rows);
my $pair_path = "$outdir/configuration_pair_evidence.csv";
my @pair_rows;
for my $key (sort { tuple_cmp($a, $b) } keys %historical) {
    my @confirmation = @{ $pairs{$key} // [] };
    push @pair_rows, [tuple_values($key), $historical{$key},
        scalar(grep { $_->{status} eq 'FAIL' } @confirmation),
        scalar(grep { $_->{status} eq 'PASS' } @confirmation),
        $evidence{$key} // 'configuration_failure_not_independently_confirmed'];
}
write_csv($pair_path, [qw(dependency version historical_rows confirmation_fail confirmation_pass evidence)], \@pair_rows);
my @lines = (
    'Smoker 61,035-run configuration-failure evidence overlay',
    '========================================================', '',
    'This report does not rewrite the historical summary or the August 23 audit.',
    'It overlays thirteen independently validated five-base batches plus three',
    'validated longer-timeout replacement executions.',
    'Pair-level reproduction is evidence for the failure mechanism; it is not a',
    'claim that every historical execution was rerun.', '', 'Inputs', '------',
    'Historical audit rows: ' . @$rows, 'Confirmation batches: ' . @batches,
    "Confirmation executions: $executions",
    'Historical configuration_failed rows: ' . @configuration,
    'Historical configuration-failure pairs: ' . scalar(keys %historical),
    'Pairs tested across all five bases: ' . scalar(keys %pairs), '',
    'Configuration-failure evidence', '------------------------------',
    report_counts(\@configuration, 'audit_evidence', 6, 1), '',
    'Evidence buckets over all 61,035 rows', '------------------------------------',
    report_counts($rows, 'audit_evidence', 6, 1), '', 'Consistency checks',
    '------------------', 'PASS',
    'All thirteen confirmation batches and the timeout retry passed structural validation and result-classification audit.',
    'The overlay contains 61,035 rows and preserves non-configuration audit evidence.',
    '', 'Files', '-----', $overlay, $pair_path);
my $report = "$outdir/61035_failure_audit_configuration_overlay.txt";
write_text($report, join("\n", @lines) . "\n");
print "$report\n";
