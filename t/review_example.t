use strict;
use warnings;

use File::Compare qw(compare);
use File::Spec;
use Test::More;

use lib 'lib';
use Smoker::PlanCSV qw(canonical_row_key read_csv_file);

my $plan = 'config/plans/20_tests.csv';
my $script = 'scripts/run/20_tests.sh';
my $example = 'examples/test_results/20_tests_20260902_184920';
my $summary = File::Spec->catfile($example, 'summary.csv');
my $original_plan = File::Spec->catfile($example, 'original_plan.csv');
my $deduplicated_plan = File::Spec->catfile($example, 'plan_deduplicated.csv');
my $skipped_duplicates = File::Spec->catfile($example, 'skipped_dup.csv');

open my $script_fh, '<', $script or die "read $script: $!";
my $script_text;
{
    local $/;
    $script_text = <$script_fh>;
}
close $script_fh or die "close $script: $!";
like($script_text, qr{config/plans/20_tests\.csv},
    '20-test wrapper selects the matching plan');

my ($plan_header, $plan_rows) = read_csv_file(
    path            => $plan,
    reject_blank    => 1,
);
is(scalar(@$plan_rows), 20, 'reference plan has 20 rows');

my %plan_identity = map { canonical_row_key($_) => 1 } @$plan_rows;
is(scalar(keys %plan_identity), 20, 'reference plan has 20 unique identities');
is(compare($plan, $original_plan), 0,
    'configured plan exactly matches retained original plan');
is(compare($plan, $deduplicated_plan), 0,
    'configured plan exactly matches retained deduplicated plan');

my (undef, $skipped_rows) = read_csv_file(
    path         => $skipped_duplicates,
    reject_blank => 1,
);
is(scalar(@$skipped_rows), 0, 'retained duplicate file has no data rows');

my ($summary_header, $summary_rows) = read_csv_file(
    path            => $summary,
    reject_blank    => 1,
);
is(scalar(@$summary_rows), 20, 'reference summary has 20 rows');

my %column;
@column{@$summary_header} = (0 .. $#$summary_header);
my @plan_fields = qw(
    base mode module version dep_one dep_one_version dep_two dep_two_version
);

my (%summary_identity, %run_id);
for my $row (@$summary_rows) {
    my @identity = map { $row->[$column{$_}] } @plan_fields;
    ++$summary_identity{canonical_row_key(\@identity)};

    my $id = $row->[$column{run_id}];
    ++$run_id{$id};
    is($row->[$column{status}], 'PASS', "$id summary status is PASS");
    is($row->[$column{rc}], '0', "$id summary rc is 0");

    my $run_dir = File::Spec->catdir($example, 'runs', $id);
    my $rc_path = File::Spec->catfile($run_dir, 'rc.code');
    my $meta_path = File::Spec->catfile($run_dir, 'result.meta');

    open my $rc_fh, '<', $rc_path or die "read $rc_path: $!";
    chomp(my $rc = <$rc_fh> // '');
    close $rc_fh or die "close $rc_path: $!";
    is($rc, '0', "$id rc.code agrees with summary");

    open my $meta_fh, '<', $meta_path or die "read $meta_path: $!";
    my %meta;
    while (my $line = <$meta_fh>) {
        chomp $line;
        my ($key, $value) = split /=/, $line, 2;
        $meta{$key} = defined $value ? $value : '';
    }
    close $meta_fh or die "close $meta_path: $!";
    is($meta{run_id}, $id, "$id result.meta has matching run_id");
    is($meta{status}, 'PASS', "$id result.meta status agrees with summary");
    is($meta{rc}, '0', "$id result.meta rc agrees with summary");
}

is_deeply(\%summary_identity, \%plan_identity,
    'reference summary identities exactly match the 20-row plan');
is(scalar(keys %run_id), 20, 'reference summary has 20 unique run IDs');

my $runs_dir = File::Spec->catdir($example, 'runs');
opendir my $runs_dh, $runs_dir or die "read $runs_dir: $!";
my @run_directories = sort grep {
    $_ ne '.' && $_ ne '..' && -d File::Spec->catdir($runs_dir, $_)
} readdir $runs_dh;
closedir $runs_dh or die "close $runs_dir: $!";
is(scalar(@run_directories), 20, 'reference example has exactly 20 run directories');
is_deeply(\@run_directories, [sort keys %run_id],
    'reference example has no missing or extra run directories');

for my $report_check (
    ['validation_evidence.txt' => qr/^  Satisfied:\s+20$/m,
        'validator reports 20 satisfied execution paths'],
    ['validation_evidence.txt' => qr/^  Unsatisfied:\s+0$/m,
        'validator reports zero unsatisfied execution paths'],
    ['validation_evidence.txt' => qr/^Assessment: PASS$/m,
        'validator final assessment is PASS'],
    ['result_classification_audit.txt' => qr/^Classified: 20$/m,
        'classification audit reports 20 classified results'],
    ['result_classification_audit.txt' => qr/^Unclassified: 0$/m,
        'classification audit reports zero unclassified results'],
) {
    my ($filename, $pattern, $label) = @$report_check;
    my $path = File::Spec->catfile($example, $filename);
    open my $fh, '<', $path or die "read $path: $!";
    local $/;
    my $text = <$fh>;
    close $fh or die "close $path: $!";
    like($text, $pattern, $label);
}

done_testing;

exit 0;
