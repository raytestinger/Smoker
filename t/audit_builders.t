use strict;
use warnings;
use utf8;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use File::Spec;
use Text::CSV;
use Digest::SHA qw(sha256_hex);

my $tmp = tempdir(CLEANUP => 1);
my $root = "$tmp/development";
my $results = "$root/test_results";
my $tools = File::Spec->rel2abs('analysis/bin');
my @plan = qw(base mode module version dep_one dep_one_version dep_two dep_two_version);
my @fields = (qw(run_id batch), @plan, qw(status rc start_ts end_ts elapsed_s run_dir note
    historical_taxonomy failed_dependency failed_dependency_version audit_evidence known_unavailable_target));
my @bases = map { "perl:5.$_" } (34, 36, 38, 40, 42);

sub text {
    my ($path, $value) = @_;
    my (undef, $dir) = File::Spec->splitpath($path); make_path($dir);
    open my $fh, '>:encoding(UTF-8)', $path or die "$path: $!";
    print {$fh} $value; close $fh or die "$path: $!";
}
sub slurp {
    my ($path) = @_;
    open my $fh, '<:raw', $path or die "$path: $!";
    local $/; my $s = <$fh>; close $fh; return $s;
}
sub csv_write {
    my ($path, $header, $rows) = @_;
    my (undef, $dir) = File::Spec->splitpath($path); make_path($dir);
    open my $fh, '>:encoding(UTF-8)', $path or die "$path: $!";
    my $csv = Text::CSV->new({binary => 1, eol => "\r\n", auto_diag => 2});
    $csv->print($fh, $header);
    $csv->print($fh, [@$_{@$header}]) for @$rows;
    close $fh or die "$path: $!";
}
sub csv_read {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "$path: $!";
    my $csv = Text::CSV->new({binary => 1, auto_diag => 2});
    $csv->column_names(@{ $csv->getline($fh) });
    my @rows; while (my $r = $csv->getline_hr($fh)) { push @rows, $r; }
    close $fh; return \@rows;
}
sub row {
    return { (map { $_ => '' } @fields), base => $bases[0], mode => 'baseline',
        module => 'Target', version => '01.00', status => 'PASS', rc => '0',
        run_id => '000001', end_ts => '2026-08-26T00:00:00Z',
        historical_taxonomy => 'historical_pass', audit_evidence => 'historical_pass', @_ };
}
sub batch {
    my ($name, $rows, $requested_plan) = @_;
    my $dir = "$results/$name";
    text("$dir/validation_evidence.txt", "Assessment: PASS\n");
    text("$dir/result_classification_audit.txt", "Classification evidence: PASS\n");
    csv_write("$dir/summary.csv", \@fields, $rows);
    text("$dir/batch_info.txt", "requested_plan_path=/plans/$requested_plan\n") if defined $requested_plan;
    return $dir;
}
my $invocation = 0;
sub run_builder {
    my ($name, @args) = @_;
    my $log = "$tmp/command-" . ++$invocation . '.log';
    my $pid = fork(); die "fork: $!" unless defined $pid;
    if (!$pid) {
        open STDOUT, '>', $log or die $!;
        open STDERR, '>&', \*STDOUT or die $!;
        exec $^X, "$tools/$name.pl", @args;
        die "exec: $!";
    }
    waitpid($pid, 0);
    return ($? >> 8, slurp($log));
}
sub rejects {
    my ($name, $message, $pattern, @args) = @_;
    my ($rc, $log) = run_builder($name, @args);
    isnt($rc, 0, $message); like($log, $pattern, "$message: reason");
}

my @builders = qw(build_61035_configuration_overlay build_61035_dependency_overlay
    build_61035_other_failure_overlay build_61035_missing_prerequisite_overlay
    build_missing_prerequisite_frontier build_failure_inventory);
rejects($_, "$_ rejects missing arguments", qr/[Uu]sage:/) for @builders;

# Independent expected bytes exercise CSV escaping, Unicode, CRLF and LF.
my @inventory_rows = (
    row(status => 'FAIL', rc => '2', module => 'Unavail', note => 'Target installation/test failed for Unavail 01.00 (rc=2)'),
    row(status => 'FAIL', rc => '2', note => "quoted, \"café\"\nsecond line"),
    row(status => 'FAIL', rc => '2', note => '0'),
    row(status => 'FAIL', rc => '8', note => 'Configuration failed for Dependency 1.0'),
    row(status => 'FAIL', rc => '2', note => 'Dependency version First 1.0; Dependency version Last 2.0 did not remain installed'),
    row(status => 'PASS', rc => '0', note => 'not a failure'));
my $inventory_input = "$tmp/inventory-input.csv";
csv_write($inventory_input, \@fields, \@inventory_rows);
csv_write("$tmp/availability.csv", \@fields, [row(module => 'Unavail', status => 'UNAVAILABLE', rc => '111')]);
my ($rc, $log) = run_builder('build_failure_inventory', $inventory_input, "$tmp/inventory", "$tmp/availability.csv");
is($rc, 0, 'inventory accepts quoted multiline Unicode and availability evidence') or diag $log;
my $inventory = csv_read("$tmp/inventory/failure_inventory.csv");
is(scalar @$inventory, 5, 'inventory includes each FAIL and excludes PASS');
my %inventory_by = map { $_->{root_cause} => $_ } @$inventory;
is($inventory_by{'Unavail 01.00'}{category}, 'target_release_confirmed_unavailable', 'confirmed unavailable release is distinguished');
is($inventory_by{'0'}{example_note}, '0', 'string zero remains a nonempty cause');
is($inventory_by{'Last 2.0'}{category}, 'dependency_replaced', 'last dependency specification supplies replaced cause');
ok(exists $inventory_by{"quoted, \"café\"\nsecond line"}, 'multiline Unicode note round trips');
unlike(slurp("$tmp/inventory/failure_inventory.csv"), qr/\r\n/, 'inventory retains LF records');
($rc, $log) = run_builder('build_failure_inventory', $inventory_input, "$tmp/inventory", "$tmp/availability.csv");
is($rc, 0, 'inventory retains its existing-output-directory behavior');

# Build historical input with exact accounting, plus configuration confirmation
# branches and longer-timeout replacements. No live Docker/CPAN is involved.
my @historical;
my @config_batches;
for my $number (1 .. 13) {
    my @confirm;
    for my $j (0 .. 11) {
        my $index = ($number - 1) * 12 + $j;
        my $dep = sprintf 'Config%03d', $index;
        push @historical, row(historical_taxonomy => 'configuration_failed', status => 'FAIL', rc => '1',
            note => "Configuration failed for $dep 01.00; quoted, \"é\"", audit_evidence => 'old_config');
        for my $b (0 .. 4) {
            my ($status, $code, $note) = ('FAIL', '1', "Configuration failed for $dep 01.00");
            if ($index == 0 || ($index == 1 && $b < 2)) { ($status, $code, $note) = ('PASS', '0', ''); }
            if ($index == 2 && $b < 2) { $note = "Installation failed while applying dependency version $dep 01.00"; }
            if (($index == 3 && $b < 3) || ($index == 4 && $b == 0)) { ($code, $note) = ('8', 'timeout'); }
            push @confirm, row(dep_one => $dep, dep_one_version => '01.00', base => $bases[$b],
                status => $status, rc => $code, note => $note);
        }
    }
    push @config_batches, batch("60_configuration_failure_confirmation_${number}_20260826", \@confirm);
}
# An older failed candidate must not override the latest named batch.
batch('60_configuration_failure_confirmation_1_20260825', []);
text("$results/60_configuration_failure_confirmation_1_20260825/validation_evidence.txt", "Assessment: FAIL\n");
my @retry = map { row(dep_one => 'Config003', dep_one_version => '01.00', base => $bases[$_],
    status => 'FAIL', rc => '1', note => 'Configuration failed for Config003 01.00') } 0 .. 2;
batch('3_configuration_timeout_retry_20260826', \@retry);

my @plans = ('25_top_dependency_failure_confirmation.csv', '50_dependency_failure_confirmation_final.csv',
    '60_dependency_failure_confirmation.csv', '30_dependency_failure_confirmation_final.csv',
    '30_dependency_safe_target_confirmation.csv', '10_roletiny_1_000000_confirmation.csv',
    '5_data_yaml_writer_v0_0_7_confirmation.csv', '5_netsockaddr_v1_1_4_confirmation.csv',
    map { "60_dependency_failure_confirmation_$_.csv" } 2 .. 11);
my @dependency_pairs = (['Role::Tiny', '1.000000'], map { [sprintf('Dep%03d', $_), '01.00'] } 1 .. 139);
my @plan_rows = map { [] } @plans;
for my $i (0 .. $#dependency_pairs) {
    my ($dep, $version) = @{ $dependency_pairs[$i] };
    my @confirm;
    for my $b (0 .. 4) {
        my ($status, $code, $note) = ('FAIL', '1', "Installation failed while applying dependency version $dep $version");
        if ($i == 0 || $i == 1) { ($status, $code, $note) = ('PASS', '0', ''); }
        if ($i == 2) { ($status, $code, $note) = ('UNAVAILABLE', '111', "unavailable exact release: requested $dep\@$version"); }
        if ($i == 3) { ($code, $note) = ('2', "Dependency version $dep $version did not remain installed"); }
        if ($i == 4 && $b == 0) { ($code, $note) = ('8', 'timeout'); }
        push @confirm, row(dep_one => $dep, dep_one_version => $version, base => $bases[$b], status => $status, rc => $code, note => $note);
        push @confirm, row(dep_one => $dep, dep_one_version => $version, base => $bases[$b], status => 'FAIL', rc => '2') if $i == 0;
    }
    push @{ $plan_rows[$i % @plans] }, @confirm;
}
my @dependency_batches;
for my $i (0 .. $#plans) {
    my $dir = batch("dependency_$i", $plan_rows[$i], $plans[$i]);
    utime(1000 + $i, 1000 + $i, $dir); push @dependency_batches, $dir;
}
# A newer all-framework-failure batch must be excluded, not selected.
my $infra = batch('dependency_infrastructure', [row(status => 'FAIL', rc => '125')], $plans[0]);
utime(9000, 9000, $infra);
# A later valid batch supersedes an older one for the same requested plan.
my $replacement = batch('dependency_newer', $plan_rows[1], $plans[1]);
utime(8000, 8000, $replacement);
batch('3467_stale_loader_verifier_recalibration_20260823_185506', []);
batch('122_dependency_availability_check_20260821_233929', []);
push @dependency_pairs, ['IO::All', '0.10'], ['File::Find::Object::Rule', '0.0100'], ['DateTime::Span', '0.3900'], ['Plack::MIME', '0.9000'];
for my $i (0 .. 6672) {
    my ($dep, $version) = @{ $dependency_pairs[$i % @dependency_pairs] };
    push @historical, row(historical_taxonomy => 'dependency_install_failed', status => 'FAIL', rc => '1',
        failed_dependency => $dep, failed_dependency_version => $version, audit_evidence => 'old_dependency');
}
my @prerequisite_rows;
for my $i (0 .. 1036) {
    my $mechanism = sprintf 'Prereq%02d', $i % 12;
    my $r = row(historical_taxonomy => 'missing_prerequisite', status => 'FAIL', rc => '1',
        module => "Target$mechanism", base => $bases[int($i / 12) % 5], note => "Missing prerequisite: $mechanism; details",
        mode => $i < 60 ? 'baseline' : 'vary-one', dep_one => $i < 60 ? '' : 'Dependency',
        run_id => sprintf('%06d', $i + 1000), audit_evidence => 'old_prerequisite');
    push @prerequisite_rows, $r; push @historical, $r;
}
for my $name ('15_local_mirror_archive_fallback_20260823_221109', '254_historical_classification_check_20260820_230615', '25_remaining_target_availability_20260823_211757') { batch($name, []); }
for my $pair (['Bio::AlignIO::selex', 'v1.7.8'], ['Bio::DB::BigWig', '1.07'], ['Alien::LibUSB', '0.4']) {
    push @historical, row(historical_taxonomy => 'other_fail', status => 'FAIL', rc => '1', module => $pair->[0], version => $pair->[1], audit_evidence => 'old_other');
}
text("$tmp/timeout/result.meta", "subtype=timeout\nraw_return_code=124\n");
push @historical, row(historical_taxonomy => 'timeout', status => 'FAIL', rc => '8', run_id => '009756', run_dir => "$tmp/timeout", audit_evidence => 'old_timeout');
push @historical, row(run_id => '060000', note => "untouched, \"é\"\nline") while @historical < 61035;
my $historical_path = "$root/analysis/61035_audit_20260823/61035_failure_audit.csv";
csv_write($historical_path, \@fields, \@historical);
my $original_hash = sha256_hex(slurp($historical_path));

($rc, $log) = run_builder('build_61035_configuration_overlay', '--development', $root, '--output', "$tmp/config");
is($rc, 0, 'configuration overlay accepts thirteen batches and three retries') or diag $log;
my $config_path = "$tmp/config/61035_failure_audit_configuration_overlay.csv";
my $config = csv_read($config_path);
is(scalar @$config, 61035, 'configuration overlay preserves row count');
is_deeply([map { $_->{audit_evidence} } @$config[0 .. 4]], [qw(configuration_pair_not_reproduced
    configuration_pair_version_dependent configuration_pair_mixed_failure_mechanism
    configuration_pair_reproduced_all_bases configuration_pair_confirmation_inconclusive)],
    'configuration branch classification and retry replacement');
is($config->[-1]{note}, "untouched, \"é\"\nline", 'unrelated quoted Unicode evidence preserved');
like(slurp($config_path), qr/\r\n/, 'overlay retains CRLF records');
my $config_hash = sha256_hex(slurp($config_path));
rejects('build_61035_configuration_overlay', 'existing overlay directory rejected', qr/output already exists/,
    '--development', $root, '--output', "$tmp/config");
is(sha256_hex(slurp($config_path)), $config_hash, 'existing output left unchanged');
text("$config_batches[0]/validation_evidence.txt", "Assessment: FAIL\n");
rejects('build_61035_configuration_overlay', 'failed validation rejected', qr/validation did not pass/,
    '--development', $root, '--output', "$tmp/reject-config");
ok(!-e "$tmp/reject-config", 'rejected evidence creates no overlay');
text("$config_batches[0]/validation_evidence.txt", "Assessment: PASS\n");

($rc, $log) = run_builder('build_61035_dependency_overlay', '--development', $root, '--input-overlay', $config_path, '--output', "$tmp/dependency");
is($rc, 0, 'dependency overlay handles latest batches and ignores framework-only batch') or diag $log;
my $dependency_path = "$tmp/dependency/61035_failure_audit_combined_overlay.csv";
my $pair_rows = csv_read("$tmp/dependency/dependency_pair_evidence.csv");
my %pair_evidence = map { $_->{dependency} => $_ } @$pair_rows;
is(scalar @$pair_rows, 144, '144 historical dependency pairs retained');
is($pair_evidence{'Role::Tiny'}{evidence}, 'dependency_pair_pass_or_did_not_remain', 'Role::Tiny ten-row exception retained');
is($pair_evidence{Dep001}{source_batch}, 'dependency_newer', 'latest eligible requested-plan batch chosen');
is($pair_evidence{Dep001}{evidence}, 'dependency_install_failure_not_reproduced', 'all-pass dependency group');
is($pair_evidence{Dep002}{evidence}, 'dependency_release_confirmed_unavailable', 'unavailable dependency group');
is($pair_evidence{Dep003}{evidence}, 'dependency_pair_did_not_remain', 'replaced dependency group');
is($pair_evidence{Dep004}{evidence}, 'dependency_pair_confirmation_inconclusive', 'mixed dependency evidence remains inconclusive');
is($pair_evidence{Dep005}{evidence}, 'dependency_install_failure_reproduced_all_bases', 'installation failure group');
is($pair_evidence{'DateTime::Span'}{evidence}, 'dependency_release_confirmed_unavailable', 'validated supplemental evidence used');
text("$dependency_batches[2]/result_classification_audit.txt", "Classification evidence: FAIL\n");
rejects('build_61035_dependency_overlay', 'failed classification audit rejected', qr/classification evidence did not pass/,
    '--development', $root, '--input-overlay', $config_path, '--output', "$tmp/reject-dependency");
text("$dependency_batches[2]/result_classification_audit.txt", "Classification evidence: PASS\n");

($rc, $log) = run_builder('build_61035_other_failure_overlay', '--development', $root, '--input-overlay', $dependency_path, '--output', "$tmp/other");
is($rc, 0, 'other-failure overlay uses explicit causal timeout state') or diag $log;
my $final_path = "$tmp/other/61035_failure_audit_final_overlay.csv";
my $other = csv_read($final_path);
my @other_labels = map { $_->{audit_evidence} } grep { $_->{historical_taxonomy} eq 'other_fail' || $_->{historical_taxonomy} eq 'timeout' } @$other;
is_deeply(\@other_labels, [qw(local_mirror_archive_failure_recalibrated target_release_now_proven_unavailable
    target_download_failure_reproduced_all_bases timeout_supported_by_explicit_causal_state)], 'other-failure branches retained');
text("$tmp/timeout/result.meta", "subtype=timeout\nraw_return_code=137\n");
rejects('build_61035_other_failure_overlay', 'timeout without raw causal code rejected', qr/timeout lacks explicit evidence/,
    '--development', $root, '--input-overlay', $dependency_path, '--output', "$tmp/reject-timeout");
text("$tmp/timeout/result.meta", "subtype=timeout\nraw_return_code=124\n");

($rc, $log) = run_builder('build_missing_prerequisite_frontier', '--input-overlay', $final_path, '--output', "$tmp/frontier");
is($rc, 0, 'frontier selects exact historical five-base representatives') or diag $log;
my $source_path = "$tmp/frontier/60_missing_prerequisite_exact_confirmation_sources.csv";
my $sources = csv_read($source_path);
is(scalar @$sources, 60, 'frontier selects sixty source rows');
is(scalar(grep { $_->{mode} eq 'baseline' } @$sources), 60, 'simplest baseline representatives preferred');
is($sources->[0]{historical_run_id}, '001000', 'lexical run identity preserves leading zeros');
my @confirmation;
for my $s (@$sources) {
    push @confirmation, row((map { $_ => $s->{$_} } @plan), status => 'FAIL', rc => '1', note => "Missing prerequisite: $s->{missing_prerequisite}");
}
my $prereq_batch = batch('prerequisite-confirmation', \@confirmation);
($rc, $log) = run_builder('build_61035_missing_prerequisite_overlay', '--input-overlay', $final_path,
    '--batch', $prereq_batch, '--sources', $source_path, '--output', "$tmp/prerequisite");
is($rc, 0, 'prerequisite overlay validates twelve five-row groups') or diag $log;
my $prereq = csv_read("$tmp/prerequisite/61035_failure_audit_post_prerequisite_overlay.csv");
is(scalar(grep { $_->{audit_evidence} eq 'missing_prerequisite_mechanism_reproduced_all_bases' } @$prereq), 1037, 'all 1,037 prerequisite rows assigned');
$confirmation[0]{note} = 'Missing prerequisite: DIFFERENT';
csv_write("$prereq_batch/summary.csv", \@fields, \@confirmation);
rejects('build_61035_missing_prerequisite_overlay', 'different reproduced mechanism rejected', qr/mechanism did not reproduce cleanly/,
    '--input-overlay', $final_path, '--batch', $prereq_batch, '--sources', $source_path, '--output', "$tmp/reject-mechanism");
csv_write("$tmp/short.csv", \@fields, [row()]);
rejects('build_missing_prerequisite_frontier', 'frontier rejects changed accounting', qr/expected 1,037/,
    '--input-overlay', "$tmp/short.csv", '--output', "$tmp/reject-frontier");
is(sha256_hex(slurp($historical_path)), $original_hash, 'historical input remains byte-identical');
done_testing();
