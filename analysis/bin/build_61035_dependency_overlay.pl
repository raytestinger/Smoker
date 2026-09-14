#!/usr/bin/env perl
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Cwd qw(abs_path);
use File::Basename qw(basename);
use Time::HiRes qw(stat);
use Smoker::AuditIO qw(options read_csv write_csv read_text write_text new_output
    require_evidence tuple tuple_values tuple_cmp report_counts children);

my %plans = map { $_ => 1 } (
    '25_top_dependency_failure_confirmation.csv',
    '50_dependency_failure_confirmation_final.csv',
    '60_dependency_failure_confirmation.csv',
    '30_dependency_failure_confirmation_final.csv',
    '30_dependency_safe_target_confirmation.csv',
    '10_roletiny_1_000000_confirmation.csv',
    '5_data_yaml_writer_v0_0_7_confirmation.csv',
    '5_netsockaddr_v1_1_4_confirmation.csv',
    map { "60_dependency_failure_confirmation_$_.csv" } 2 .. 11);

sub classify_pair {
    my ($key, $rows) = @_;
    my ($module, $version) = tuple_values($key);
    my $install = "while applying dependency version $module $version";
    my $config = "Configuration failed for $module $version";
    my $unavailable = "unavailable exact release: requested $module\@$version";
    my $replaced = "Dependency version $module $version did not remain installed";
    if ($module eq 'Role::Tiny' && $version eq '1.000000' && @$rows == 10) {
        my $pass = grep { $_->{status} eq 'PASS' && $_->{rc} eq '0' } @$rows;
        my $fail = grep { $_->{status} eq 'FAIL' && $_->{rc} eq '2' } @$rows;
        return 'dependency_pair_pass_or_did_not_remain' if $pass == 5 && $fail == 5;
    }
    return 'dependency_pair_confirmation_inconclusive' unless @$rows == 5;
    return 'dependency_install_failure_not_reproduced'
        unless grep { $_->{status} ne 'PASS' || $_->{rc} ne '0' } @$rows;
    return 'dependency_install_failure_reproduced_all_bases'
        unless grep { $_->{rc} ne '1' || (index($_->{note}, $install) < 0 && index($_->{note}, $config) < 0) } @$rows;
    return 'dependency_release_confirmed_unavailable'
        unless grep { $_->{status} ne 'UNAVAILABLE' || index($_->{note}, $unavailable) < 0 } @$rows;
    return 'dependency_pair_did_not_remain'
        unless grep { $_->{rc} ne '2' || index($_->{note}, $replaced) < 0 } @$rows;
    return 'dependency_pair_confirmation_inconclusive';
}

my $args = options(qw(development input-overlay output));
my $root = abs_path($args->{development}) // die "development directory not found\n";
my (%latest, @plan_order);
for my $dir (children("$root/test_results")) {
    next unless -f "$dir/batch_info.txt";
    my %info;
    for my $line (split /\r?\n/, read_text("$dir/batch_info.txt")) {
        my ($key, $value) = split /=/, $line, 2;
        $info{$key} = $value if defined $value;
    }
    my $plan = basename($info{requested_plan_path} // '');
    next unless $plans{$plan};
    next if grep { !-f "$dir/$_" } qw(summary.csv validation_evidence.txt result_classification_audit.txt);
    require_evidence($dir);
    my ($summary) = read_csv("$dir/summary.csv");
    # Structurally complete sandbox failures are not dependency evidence.
    next if @$summary && !grep { $_->{status} ne 'FAIL' || $_->{rc} ne '125' } @$summary;
    if (!exists $latest{$plan}) {
        push @plan_order, $plan;
        $latest{$plan} = $dir;
    }
    elsif ((stat($dir))[9] > (stat($latest{$plan}))[9]) { $latest{$plan} = $dir; }
}
my @missing = sort grep { !exists $latest{$_} } keys %plans;
die 'missing plans: ' . join(', ', @missing) . "\n" if @missing;
my %selected;
for my $plan (@plan_order) {
    my $dir = $latest{$plan};
    my ($rows) = read_csv("$dir/summary.csv");
    my %groups;
    for my $row (@$rows) { push @{ $groups{tuple($row->{dep_one}, $row->{dep_one_version})} }, $row; }
    for my $pair (keys %groups) {
        my $group = $groups{$pair};
        my ($end) = sort { $b cmp $a } map { $_->{end_ts} } @$group;
        # Preserve the first candidate on equal timestamps, like Python max().
        if (!exists $selected{$pair} || $end gt $selected{$pair}{end}) {
            $selected{$pair} = { end => $end, dir => $dir, rows => $group };
        }
    }
}
my (%evidence, %source);
for my $pair (keys %selected) {
    $evidence{$pair} = classify_pair($pair, $selected{$pair}{rows});
    $source{$pair} = basename($selected{$pair}{dir});
}
my @supplements = (
    ['IO::All', '0.10', 'dependency_install_failure_reproduced_all_bases', '3467_stale_loader_verifier_recalibration_20260823_185506'],
    ['File::Find::Object::Rule', '0.0100', 'dependency_install_failure_reproduced_all_bases', '3467_stale_loader_verifier_recalibration_20260823_185506'],
    ['DateTime::Span', '0.3900', 'dependency_release_confirmed_unavailable', '122_dependency_availability_check_20260821_233929'],
    ['Plack::MIME', '0.9000', 'dependency_release_confirmed_unavailable', '122_dependency_availability_check_20260821_233929']);
my %checked;
for my $item (@supplements) {
    my ($module, $version, $label, $batch) = @$item;
    require_evidence("$root/test_results/$batch") unless $checked{$batch}++;
    my $pair = tuple($module, $version);
    $evidence{$pair} = $label; $source{$pair} = $batch;
}
my ($rows, $fields) = read_csv($args->{'input-overlay'});
die "input overlay is not 61,035 rows\n" unless @$rows == 61035;
my (%historical, @dependency);
for my $row (@$rows) {
    next unless $row->{historical_taxonomy} eq 'dependency_install_failed';
    my $pair = tuple($row->{failed_dependency}, $row->{failed_dependency_version});
    ++$historical{$pair};
    $row->{audit_evidence} = $evidence{$pair} // 'dependency_failure_not_independently_confirmed';
    push @dependency, $row;
}
die "dependency accounting changed\n" unless keys(%historical) == 144 && @dependency == 6673;
my $outdir = $args->{output}; new_output($outdir);
my $overlay = "$outdir/61035_failure_audit_combined_overlay.csv";
write_csv($overlay, $fields, $rows);
my $pairs = "$outdir/dependency_pair_evidence.csv";
my @pair_rows = map { [tuple_values($_), $historical{$_},
    $evidence{$_} // 'dependency_failure_not_independently_confirmed', $source{$_} // ''] }
    sort { tuple_cmp($a, $b) } keys %historical;
write_csv($pairs, [qw(dependency version historical_rows evidence source_batch)], \@pair_rows);
my @lines = ('Smoker 61,035-run combined evidence overlay',
    '===========================================', '',
    'Dependency-install evidence (6,673 historical rows)',
    '----------------------------------------------------', report_counts(\@dependency, 'audit_evidence', 6), '',
    'Evidence buckets over all 61,035 rows', '------------------------------------',
    report_counts($rows, 'audit_evidence', 6), '', 'Consistency checks', '------------------',
    'PASS', 'All selected batches passed structural validation and classification audit.',
    'The overlay has 61,035 rows; dependency accounting is 6,673 rows across 144 pairs.',
    '', $overlay, $pairs);
my $report = "$outdir/61035_failure_audit_combined_overlay.txt";
write_text($report, join("\n", @lines) . "\n"); print "$report\n";
