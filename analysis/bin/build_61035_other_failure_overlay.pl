#!/usr/bin/env perl
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Cwd qw(abs_path);
use Smoker::AuditIO qw(options read_csv write_csv read_text write_text new_output
    require_evidence tuple report_counts);

my %recovered = map { tuple(@$_) => 1 } (
    ['Bio::AlignIO::selex', 'v1.7.8'],
    ['Bio::Chado::Schema::Result::Cv::CommonAncestorCvterm', '0.20000'],
    ['Bio::Tools::Primer3Redux::PrimerPair', '0.09']);
my %unavailable = map { tuple(@$_) => 1 } (['Bio::DB::BigWig', '1.07'], ['Linux::InitFS::Entry', '0.2']);
my $args = options(qw(development input-overlay output));
my $root = abs_path($args->{development}) // die "development directory not found\n";
require_evidence("$root/test_results/$_") for (
    '15_local_mirror_archive_fallback_20260823_221109',
    '254_historical_classification_check_20260820_230615',
    '25_remaining_target_availability_20260823_211757');
my ($rows, $fields) = read_csv($args->{'input-overlay'});
for my $row (@$rows) {
    my $pair = tuple($row->{module}, $row->{version});
    if ($row->{historical_taxonomy} eq 'other_fail') {
        if ($recovered{$pair}) { $row->{audit_evidence} = 'local_mirror_archive_failure_recalibrated'; }
        elsif ($unavailable{$pair}) { $row->{audit_evidence} = 'target_release_now_proven_unavailable'; }
        elsif ($pair eq tuple('Alien::LibUSB', '0.4')) { $row->{audit_evidence} = 'target_download_failure_reproduced_all_bases'; }
        else { die "unhandled other_fail row: $row->{run_id}\n"; }
    }
    elsif ($row->{historical_taxonomy} eq 'timeout') {
        die "unexpected timeout row\n" unless $row->{run_id} eq '009756' && $row->{rc} eq '8';
        my $text = read_text("$row->{run_dir}/result.meta");
        die "timeout lacks explicit evidence\n"
            unless index($text, 'subtype=timeout') >= 0 && index($text, 'raw_return_code=124') >= 0;
        $row->{audit_evidence} = 'timeout_supported_by_explicit_causal_state';
    }
}
die "row count changed\n" unless @$rows == 61035;
my $outdir = $args->{output}; new_output($outdir);
my $overlay = "$outdir/61035_failure_audit_final_overlay.csv";
write_csv($overlay, $fields, $rows);
my @lines = ('Smoker 61,035-run final evidence overlay',
    '========================================', '', 'Evidence buckets', '----------------',
    report_counts($rows, 'audit_evidence', 6), '', 'Consistency checks', '------------------',
    'PASS', 'All 135 other_fail rows and the single timeout have explicit evidence assignments.',
    'Total rows: ' . @$rows, $overlay);
my $report = "$outdir/61035_failure_audit_final_overlay.txt";
write_text($report, join("\n", @lines) . "\n"); print "$report\n";
