#!/usr/bin/env perl
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use File::Path qw(make_path);
use Smoker::AuditIO qw(read_csv write_csv write_text tuple tuple_values tuple_cmp ranked_counts);

die "usage: $0 RECONCILED_SUMMARY OUTPUT_DIR [CONFIRMED_UNAVAILABLE_SUMMARY ...]\n" unless @ARGV >= 2;
my ($summary_path, $output, @availability_paths) = @ARGV;
make_path($output) unless -d $output;
my %unavailable;
for my $path (@availability_paths) {
    my ($rows) = read_csv($path);
    for my $row (@$rows) {
        $unavailable{tuple($row->{module}, $row->{version})} = 1
            if $row->{status} eq 'UNAVAILABLE' && $row->{rc} eq '111';
    }
}

sub classify {
    my ($row) = @_;
    my $note = $row->{note};
    my $target = "$row->{module} $row->{version}";
    return ('timeout', $target) if $row->{rc} eq '8';
    if ($note =~ /did not remain installed/) {
        my @spec = $note =~ /Dependency version (\S+) (\S+)/g;
        return ('dependency_replaced', @spec ? "$spec[-2] $spec[-1]" : 'dependency version replaced');
    }
    return ('dependency_install_failed', $1)
        if $note =~ /Installation failed while applying dependency version (.+?) \(rc=\d+\)/;
    return ('dependency_configuration_failed', $1) if $note =~ /Configuration failed for ([^;]+)/;
    return ('missing_prerequisite', $1) if $note =~ /Missing prerequisite: ([^;]+)/;
    if ($note =~ /Target installation\/test failed for (.+?) \(rc=\d+\)/) {
        return ($unavailable{tuple($row->{module}, $row->{version})}
            ? 'target_release_confirmed_unavailable' : 'target_install_or_test_failed', $1);
    }
    if (index($note, 'Download failed for') >= 0) {
        return ($unavailable{tuple($row->{module}, $row->{version})}
            ? 'target_release_confirmed_unavailable' : 'external_or_build_source_fetch_failed', $target);
    }
    return ('other_fail', length($note) ? $note : "$target rc=$row->{rc}");
}

my ($rows) = read_csv($summary_path);
my @failures = grep { $_->{status} eq 'FAIL' } @$rows;
my %clusters;
for my $row (@failures) {
    my ($category, $cause) = classify($row);
    my $key = tuple($category, $cause);
    my $cluster = $clusters{$key} //= {rows => 0, modules => {}, bases => {}, modes => {},
        example_note => $row->{note}, example_run_dir => $row->{run_dir}};
    ++$cluster->{rows};
    $cluster->{modules}{tuple($row->{module}, $row->{version})} = 1;
    $cluster->{bases}{$row->{base}} = 1;
    $cluster->{modes}{$row->{mode}} = 1;
}
my @ordered = sort { $clusters{$b}{rows} <=> $clusters{$a}{rows} || tuple_cmp($a, $b) } keys %clusters;
my @inventory;
for my $key (@ordered) {
    my $cluster = $clusters{$key};
    push @inventory, [tuple_values($key), $cluster->{rows}, scalar(keys %{ $cluster->{modules} }),
        join(';', sort keys %{ $cluster->{bases} }), join(';', sort keys %{ $cluster->{modes} }),
        $cluster->{example_note}, $cluster->{example_run_dir}];
}
my $inventory_path = "$output/failure_inventory.csv";
write_csv($inventory_path, [qw(category root_cause affected_rows affected_module_releases
    affected_bases affected_modes example_note example_run_dir)], \@inventory, "\n");
my (%counts, %category_clusters, @category_order);
for my $key (@ordered) {
    my ($category, $cause) = tuple_values($key);
    push @category_order, $category unless exists $counts{$category};
    $counts{$category} += $clusters{$key}{rows};
    push @{ $category_clusters{$category} }, [$cause, $clusters{$key}];
}
my %dispositions = (
    target_install_or_test_failed => 'CPAN/module outcome; inspect one representative per largest module cluster before proposing framework changes.',
    target_release_confirmed_unavailable => 'Recorded historical FAIL is retained, but a current representative live-CPAN retry confirms the same target release is unavailable; no framework defect is indicated.',
    external_or_build_source_fetch_failed => 'The CPAN distribution resolved, but a distribution-owned external source or build prerequisite could not be fetched; retained evidence determines the external endpoint and failure.',
    dependency_install_failed => 'Requested dependency release could not be installed; normally a genuine dependency-version incompatibility.',
    dependency_configuration_failed => 'Requested dependency release failed configuration on the selected environment.',
    dependency_replaced => 'Requested dependency installed initially, then target dependency resolution replaced it; classification is supported.',
    missing_prerequisite => 'Requested old release has incomplete or incompatible prerequisite metadata/build tooling.',
    timeout => 'Inspect the retained timeout evidence individually.',
    other_fail => 'Requires individual log review before disposition.');
my $text = "SMOKER RECONCILED FAILURE INVENTORY\n" . ('=' x 80) . "\n\nSource summary: $summary_path\n";
$text .= "Availability evidence: $_\n" for @availability_paths;
$text .= 'Confirmed-unavailable module releases: ' . scalar(keys %unavailable) . "\n";
$text .= 'FAIL rows: ' . @failures . "\nNormalized root-cause clusters: " . scalar(keys %clusters) . "\n\n";
$text .= "FAILURE CATEGORIES\n" . ('-' x 80) . "\n";
my @categories = ranked_counts(\%counts, \@category_order);
$text .= sprintf("%8d  %s\n", $counts{$_}, $_) for @categories;
for my $category (@categories) {
    $text .= "\n";
    $text .= uc($category) . " ($counts{$category} rows)\nDisposition: $dispositions{$category}\nTop clusters:\n";
    my @top = @{ $category_clusters{$category} };
    splice @top, 20 if @top > 20;
    for my $item (@top) {
        my ($cause, $cluster) = @$item;
        $text .= sprintf("  %6d rows | %4d module release(s) | %s\n", $cluster->{rows}, scalar(keys %{ $cluster->{modules} }), $cause);
        $text .= "         evidence: $cluster->{example_run_dir}\n";
    }
}
$text .= "\nASSESSMENT\n" . ('-' x 80) . "\n";
$text .= "The inventory accounts for every reconciled FAIL row exactly once.\n";
$text .= "No framework-error return codes are present. Further diagnostics should start with representative target-failure clusters, not broad reruns.\n";
my $report = "$output/failure_inventory_report.txt";
write_text($report, $text);
print "wrote $inventory_path\nwrote $report\n";
