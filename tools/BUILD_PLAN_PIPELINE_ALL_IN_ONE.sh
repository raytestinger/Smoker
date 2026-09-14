#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

source_packages_index="$HOME/Smoker/minicpan/modules/02packages.details.txt.gz"
packages_index=""
module_input=""
randomized_index_name="02packages.details.randomized.txt.gz"
prefix="plan"
target_modules=1000
module_limit=0
perl_versions="5.38"
max_deps=3
max_versions=2
max_pairs=0
selection_mode="ordered"
version_sampling="spread"
pair_mode="cross"
seed=20260726
sleep_ms=0

usage() {
    cat <<'USAGE'
Usage:
  BUILD_PLAN_PIPELINE_ALL_IN_ONE.sh --packages-index FILE [options]
  BUILD_PLAN_PIPELINE_ALL_IN_ONE.sh --input FILE [options]

Inputs:
  --packages-index FILE      Source CPAN index to copy and randomize
                             (default: $HOME/Smoker/minicpan/modules/02packages.details.txt.gz)
  --input FILE               Text file containing one target module per line

Output naming:
  --prefix NAME              Output prefix (default: plan)

Builder controls:
  --target-modules N         Successfully planned unique modules (default: 10)
  --module-limit N           Maximum candidate modules examined; 0 is unlimited (default: 0)
  --perl-versions LIST       Comma-separated Perl versions (default: 5.38)
  --max-deps N               Maximum dependencies per module (default: 3)
  --max-versions N           Maximum versions per dependency (default: 2)
  --max-pairs N              Maximum dependency pairs; 0 means unlimited
  --selection-mode MODE      ordered|random|balanced (default: ordered)
  --version-sampling MODE    recent|spread (default: spread)
  --pair-mode MODE           zip|grid|cross (default: cross)
  --seed N                   Reproducible random seed (default: 20260724)
  --sleep-ms N               MetaCPAN pause in milliseconds (default: 0)

Other:
  --help                     Show this help

Files produced:
  PREFIX.raw.csv
  PREFIX.manifest.json
  PREFIX.unique.csv
  PREFIX.duplicates.csv
  PREFIX.balanced.csv
  PREFIX.final.csv
  PREFIX.analysis.txt
  PREFIX.analysis.json
USAGE
}

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

clean_plan_workspace() {
    local patterns=(
      "*.raw.csv"
      "*.unique.csv"
      "*.balanced.csv"
      "*.final.csv"
      "*.duplicates.csv"
      "*.manifest.json"
      "*.analysis.txt"
      "*.analysis.json"
      "dedup_test.input.csv"
      "dedup_test.shuffled.csv"
    )
    local count=0 pat f
    shopt -s nullglob
    for pat in "${patterns[@]}"; do
      for f in $pat; do
        rm -f -- "$f"
        printf 'Removed: %s\n' "$f"
        count=$((count+1))
      done
    done
    printf '\nFiles removed: %d\n' "$count"
}

run_build_plan() {
    perl - "$@" <<'__RUN_BUILD_PLAN_PERL__'
#!/usr/bin/env perl
use strict;
use warnings;

use Getopt::Long qw(GetOptions);
use HTTP::Tiny;
use JSON::PP qw(decode_json encode_json);
use URI::Escape qw(uri_escape_utf8);
use POSIX qw(strftime);
use Module::CoreList ();
use IO::Uncompress::Gunzip qw(gunzip $GunzipError);
use List::Util qw(shuffle);

# Smoker massive-plan builder, version 4.0 (unique-module target)
#
# Emits the agreed eight-column plan schema:
#   base,mode,module,version,dep_one,dep_one_version,dep_two,dep_two_version
#
# Input may be either:
#   --input FILE
#       one target module per line
#   --packages-index FILE
#       CPAN 02packages.details.txt.gz; candidate modules are extracted locally
#
# The builder:
#   * deduplicates target modules
#   * discovers target dependencies and dependency releases through MetaCPAN
#   * samples versions using recent or spread selection
#   * canonicalizes vary-two dependency ordering
#   * rejects duplicate execution rows before writing
#   * opens the CSV, appends one accepted row, and closes it immediately
#   * completes every selected module and stops after --target-modules planned modules
#   * lets the resulting row count vary naturally with each module
#   * records generation and coverage details in a JSON manifest

my $input;
my $packages_index;
my $output;
my $manifest;
my $target_modules = 10;
my $module_limit = 0;
my $max_deps = 8;
my $max_versions = 4;
my $max_pairs = 0;
my $perl_versions = '5.34,5.36,5.38,5.40,5.42';
my $selection_mode = 'balanced';      # ordered|random|balanced
my $version_sampling = 'spread';      # recent|spread
my $pair_mode = 'cross';              # zip|grid|cross
my $include_test_requires = 0;
my $include_build_requires = 1;
my $include_acme = 0;
my $include_alien = 1;
my $seed = 20260720;
my $sleep_ms = 100;
my $api_base = 'https://fastapi.metacpan.org/v1';
my $verbose = 1;
my (@perls, $http);

sub main {

GetOptions(
    'input=s'                  => \$input,
    'packages-index=s'         => \$packages_index,
    'output=s'                 => \$output,
    'manifest=s'               => \$manifest,
    'target-modules=i'         => \$target_modules,
    'module-limit=i'           => \$module_limit,
    'max-deps=i'               => \$max_deps,
    'max-versions=i'           => \$max_versions,
    'max-pairs=i'              => \$max_pairs,
    'perl-versions=s'          => \$perl_versions,
    'selection-mode=s'         => \$selection_mode,
    'version-sampling=s'       => \$version_sampling,
    'pair-mode=s'              => \$pair_mode,
    'include-test-requires!'   => \$include_test_requires,
    'include-build-requires!'  => \$include_build_requires,
    'include-acme!'            => \$include_acme,
    'include-alien!'           => \$include_alien,
    'seed=i'                   => \$seed,
    'sleep-ms=i'               => \$sleep_ms,
    'api-base=s'               => \$api_base,
    'verbose!'                 => \$verbose,
) or die usage();

die usage() if (!$input && !$packages_index) || ($input && $packages_index);
die "--target-modules must be >= 0\n" if $target_modules < 0;
die "--module-limit must be >= 0\n" if $module_limit < 0;
die "--max-deps must be >= 0\n" if $max_deps < 0;
die "--max-versions must be >= 1\n" if $max_versions < 1;
die "--max-pairs must be >= 0\n" if $max_pairs < 0;
die "--selection-mode must be ordered, random, or balanced\n"
    unless $selection_mode =~ /\A(?:ordered|random|balanced)\z/;
die "--version-sampling must be recent or spread\n"
    unless $version_sampling =~ /\A(?:recent|spread)\z/;
die "--pair-mode must be zip, grid, or cross\n"
    unless $pair_mode =~ /\A(?:zip|grid|cross)\z/;

@perls = grep { length } map { trim($_) } split /,/, $perl_versions;
die "no Perl versions supplied\n" unless @perls;

srand($seed);

my $stamp = strftime('%Y%m%d_%H%M%S', localtime);
$output   ||= "plan_${stamp}.csv";
$manifest ||= "$output.manifest.json";

$http = HTTP::Tiny->new(
    agent      => 'SmokerPlanBuilder/4.0',
    verify_SSL => 1,
    timeout    => 45,
    default_headers => {
        accept         => 'application/json',
        'content-type' => 'application/json',
    },
);

my ($modules, $input_stats) = $input
    ? read_module_list($input)
    : read_packages_index($packages_index);

my @modules = @$modules;
if ($selection_mode ne 'ordered') {
    @modules = shuffle(@modules);
}
if ($module_limit && @modules > $module_limit) {
    @modules = @modules[0 .. $module_limit - 1];
}

initialize_csv($output);

my %seen_candidate;
my $duplicate_candidates = 0;
my $rows_written = 0;
my $planned_modules = 0;
my $attempted_modules = 0;
my @module_meta;
my (%coverage_mode, %coverage_base, %coverage_module, %coverage_dep);

write_manifest(
    status               => 'building',
    completed_at         => undef,
    input_stats          => $input_stats,
    modules              => \@module_meta,
    rows_written         => $rows_written,
    planned_modules       => $planned_modules,
    attempted_modules     => $attempted_modules,
    duplicate_candidates => $duplicate_candidates,
    coverage_mode        => \%coverage_mode,
    coverage_base        => \%coverage_base,
    coverage_module      => \%coverage_module,
    coverage_dep         => \%coverage_dep,
);

MODULE:
for my $module (@modules) {
    last MODULE if $target_modules && $planned_modules >= $target_modules;
    $attempted_modules++;
    sayerr("==> $module") if $verbose;

    my $mod = fetch_module($module);
    unless ($mod) {
        push @module_meta, { module => $module, status => 'skipped_no_module_metadata' };
        next;
    }

    my $target_version = normalize_version($mod->{version});
    $target_version = '' unless defined $target_version;

    my $release = fetch_release($mod->{distribution});
    unless ($release) {
        push @module_meta, {
            module  => $module,
            version => $target_version,
            status  => 'skipped_no_release_metadata',
        };
        next;
    }

    my @deps = select_dependencies($release, \@perls);
    @deps = choose_items(\@deps, $max_deps, $selection_mode);

    my %versions;
    my @usable;
    for my $dep (@deps) {
        my $all = fetch_dependency_versions(
            $dep->{module},
            $dep->{distribution},
        );
        my @selected = sample_versions($all, $max_versions, $version_sampling);
        $versions{$dep->{module}} = \@selected;
        push @usable, $dep if @selected;
        polite_pause($sleep_ms);
    }

    my @pairs = build_pairs(@usable);
    @pairs = choose_items(\@pairs, $max_pairs, $selection_mode) if $max_pairs;

    my %counts = ( baseline => 0, 'vary-one' => 0, 'vary-two' => 0 );

    GENERATE:
    for my $perl (@perls) {
        add_candidate(
            \%seen_candidate, \$duplicate_candidates,
            {
                base            => "perl:$perl",
                mode            => 'baseline',
                module          => $module,
                version         => $target_version,
                dep_one         => '',
                dep_one_version => '',
                dep_two         => '',
                dep_two_version => '',
            },
            $output, \$rows_written,
            \%coverage_mode, \%coverage_base,
            \%coverage_module, \%coverage_dep,
        ) and $counts{baseline}++;

        for my $dep (@usable) {
            for my $ver (@{ $versions{$dep->{module}} }) {
                add_candidate(
                    \%seen_candidate, \$duplicate_candidates,
                    {
                        base            => "perl:$perl",
                        mode            => 'vary-one',
                        module          => $module,
                        version         => $target_version,
                        dep_one         => $dep->{module},
                        dep_one_version => $ver,
                        dep_two         => '',
                        dep_two_version => '',
                    },
                    $output, \$rows_written,
                    \%coverage_mode, \%coverage_base,
                    \%coverage_module, \%coverage_dep,
                ) and $counts{'vary-one'}++;
            }
        }

        for my $pair (@pairs) {
            my ($a, $b) = @$pair;
            my @combos = build_version_combos(
                $versions{$a->{module}},
                $versions{$b->{module}},
                $pair_mode,
            );

            for my $combo (@combos) {
                my ($va, $vb) = @$combo;
                add_candidate(
                    \%seen_candidate, \$duplicate_candidates,
                    {
                        base            => "perl:$perl",
                        mode            => 'vary-two',
                        module          => $module,
                        version         => $target_version,
                        dep_one         => $a->{module},
                        dep_one_version => $va,
                        dep_two         => $b->{module},
                        dep_two_version => $vb,
                    },
                    $output, \$rows_written,
                    \%coverage_mode, \%coverage_base,
                    \%coverage_module, \%coverage_dep,
                ) and $counts{'vary-two'}++;
            }
        }
    }

    push @module_meta, {
        module              => $module,
        version             => $target_version,
        distribution        => $mod->{distribution},
        selected_dep_count  => scalar(@deps),
        usable_dep_count    => scalar(@usable),
        generated_rows      => \%counts,
        selected_deps       => [
            map {
                {
                    module       => $_->{module},
                    distribution => $_->{distribution},
                    phase        => $_->{phase},
                    versions     => $versions{$_->{module}} || [],
                }
            } @deps
        ],
        status => 'planned',
    };
    $planned_modules++;

    sayerr(sprintf(
        "    modules=%d rows=%d duplicates=%d output=%s",
        $planned_modules,
        $rows_written,
        $duplicate_candidates,
        $output,
    )) if $verbose;

    polite_pause($sleep_ms);
}

my $completed = !$target_modules || $planned_modules >= $target_modules;
my $status = $completed ? 'complete' : 'incomplete';

write_manifest(
    status               => $status,
    completed_at         => scalar localtime,
    input_stats          => $input_stats,
    modules              => \@module_meta,
    rows_written         => $rows_written,
    planned_modules       => $planned_modules,
    attempted_modules     => $attempted_modules,
    duplicate_candidates => $duplicate_candidates,
    coverage_mode        => \%coverage_mode,
    coverage_base        => \%coverage_base,
    coverage_module      => \%coverage_module,
    coverage_dep         => \%coverage_dep,
);

print "Wrote $output
";
print "Wrote $manifest
";
print "Input modules:          $input_stats->{unique_modules}
";
print "Planned modules:        $planned_modules\n";
print "Attempted modules:      $attempted_modules\n";
print "Unique rows written:    $rows_written\n";
print "Duplicate attempts:     $duplicate_candidates
";
print "Status:                 $status
";

if (!$completed) {
    die sprintf(
        "requested %d planned modules, but only %d were completed; widen inputs or raise --module-limit
",
        $target_modules,
        $planned_modules,
    );
}

    return 0;
}

sub add_candidate {
    my (
        $seen, $dups_ref, $row,
        $path, $written_ref,
        $mode_cov, $base_cov, $module_cov, $dep_cov,
    ) = @_;

    canonicalize_row($row);
    my $key = row_key($row);
    if ($seen->{$key}++) {
        $$dups_ref++;
        return 0;
    }

    append_csv_row($path, $row);
    $$written_ref++;

    $mode_cov->{ $row->{mode} }++;
    $base_cov->{ $row->{base} }++;
    $module_cov->{ $row->{module} }++;
    $dep_cov->{ $row->{dep_one} }++ if $row->{dep_one} ne '';
    $dep_cov->{ $row->{dep_two} }++ if $row->{dep_two} ne '';
    return 1;
}


sub initialize_csv {
    my ($path) = @_;
    open my $fh, '>', $path or die "open $path: $!\n";
    print {$fh} csv_row(qw(
        base mode module version dep_one dep_one_version dep_two dep_two_version
    )), "\n";
    close $fh or die "close $path: $!\n";
}

sub append_csv_row {
    my ($path, $row) = @_;
    open my $fh, '>>', $path or die "open $path for append: $!\n";
    print {$fh} csv_row(
        @{$row}{qw(
            base mode module version
            dep_one dep_one_version dep_two dep_two_version
        )}
    ), "\n";
    close $fh or die "close $path: $!\n";
}

sub write_manifest {
    my (%args) = @_;
    my %coverage = (
        rows_by_mode         => $args{coverage_mode},
        rows_by_base         => $args{coverage_base},
        rows_by_module       => $args{coverage_module},
        dependency_frequency => $args{coverage_dep},
        unique_modules       => scalar(keys %{ $args{coverage_module} }),
        unique_dependencies  => scalar(keys %{ $args{coverage_dep} }),
    );

    my %meta = (
        schema_version         => 4,
        status                 => $args{status},
        created_at             => scalar localtime,
        completed_at           => $args{completed_at},
        input                  => $input || $packages_index,
        input_type             => $input ? 'module_list' : '02packages.details',
        input_stats            => $args{input_stats},
        output                 => $output,
        manifest               => $manifest,
        seed                   => $seed,
        perl_versions          => \@perls,
        target_modules_requested => $target_modules,
        planned_modules         => $args{planned_modules},
        attempted_modules       => $args{attempted_modules},
        module_limit             => $module_limit,
        unique_rows_written    => $args{rows_written},
        duplicate_candidates   => $args{duplicate_candidates},
        selection_mode         => $selection_mode,
        version_sampling       => $version_sampling,
        pair_mode              => $pair_mode,
        max_deps               => $max_deps,
        max_versions           => $max_versions,
        max_pairs              => $max_pairs,
        include_test_requires  => $include_test_requires ? JSON::PP::true : JSON::PP::false,
        include_build_requires => $include_build_requires ? JSON::PP::true : JSON::PP::false,
        streaming_output       => JSON::PP::true,
        coverage               => \%coverage,
        modules                => $args{modules},
    );

    open my $fh, '>', $manifest or die "open $manifest: $!\n";
    print {$fh} JSON::PP->new->ascii->pretty->canonical->encode(\%meta);
    close $fh or die "close $manifest: $!\n";
}

sub canonicalize_row {
    my ($row) = @_;
    for my $k (qw(base mode module version dep_one dep_one_version dep_two dep_two_version)) {
        $row->{$k} = '' unless defined $row->{$k};
    }

    if ($row->{mode} eq 'vary-two') {
        my @a = ($row->{dep_one}, $row->{dep_one_version});
        my @b = ($row->{dep_two}, $row->{dep_two_version});
        if (join("\x1f", @b) lt join("\x1f", @a)) {
            ($row->{dep_one}, $row->{dep_two}) = ($row->{dep_two}, $row->{dep_one});
            ($row->{dep_one_version}, $row->{dep_two_version})
                = ($row->{dep_two_version}, $row->{dep_one_version});
        }
    }
}

sub row_key {
    my ($r) = @_;
    return join "\x1e", @{$r}{qw(
        base mode module version
        dep_one dep_one_version dep_two dep_two_version
    )};
}

sub choose_items {
    my ($items, $limit, $mode) = @_;
    my @copy = @$items;
    return @copy if !$limit || @copy <= $limit;
    @copy = shuffle(@copy) if $mode ne 'ordered';
    return @copy[0 .. $limit - 1];
}

sub read_module_list {
    my ($path) = @_;
    open my $fh, '<', $path or die "open $path: $!\n";
    my (%seen, @mods);
    my ($lines, $duplicates, $filtered) = (0, 0, 0);

    while (my $line = <$fh>) {
        $lines++;
        chomp $line;
        $line =~ s/\r\z//;
        $line = trim($line);
        next if $line eq '' || $line =~ /^#/;
        if (!module_allowed($line)) {
            $filtered++;
            next;
        }
        if ($seen{$line}++) {
            $duplicates++;
            next;
        }
        push @mods, $line;
    }
    close $fh;

    return (
        \@mods,
        {
            input_lines       => $lines,
            duplicate_modules => $duplicates,
            filtered_modules  => $filtered,
            unique_modules    => scalar(@mods),
        }
    );
}

sub read_packages_index {
    my ($path) = @_;
    my $gz = IO::Uncompress::Gunzip->new($path)
        or die "gunzip $path: $GunzipError\n";

    my (%seen, @mods);
    my ($lines, $duplicates, $filtered) = (0, 0, 0);
    my $in_body = 0;

    while (my $line = <$gz>) {
        $lines++;
        if (!$in_body) {
            $in_body = 1 if $line =~ /^\s*$/;
            next;
        }

        chomp $line;
        next if $line =~ /^\s*$/;
        my ($module) = split /\s+/, $line, 2;
        next unless defined $module && length $module;

        if (!module_allowed($module)) {
            $filtered++;
            next;
        }
        if ($seen{$module}++) {
            $duplicates++;
            next;
        }
        push @mods, $module;
    }
    close $gz;

    return (
        \@mods,
        {
            input_lines       => $lines,
            duplicate_modules => $duplicates,
            filtered_modules  => $filtered,
            unique_modules    => scalar(@mods),
        }
    );
}

sub module_allowed {
    my ($module) = @_;
    return 0 if $module eq 'perl';
    return 0 if $module =~ /::ConfigData\z/;
    return 0 if !$include_acme  && $module =~ /^Acme(?:::|\z)/;
    return 0 if !$include_alien && $module =~ /^Alien(?:::|\z)/;
    return 0 if $module =~ /^(?:Task|Bundle)(?:::|\z)/;
    return 1;
}

sub fetch_module {
    my ($module) = @_;
    my $url = "$api_base/module/" . uri_escape_utf8($module);
    my $res = $http->get($url);
    return unless $res->{success};
    my $obj = eval { decode_json($res->{content}) };
    return unless $obj && ref($obj) eq 'HASH';
    return $obj;
}

sub fetch_release {
    my ($distribution) = @_;
    return unless $distribution;

    my $query = {
        size    => 1,
        _source => [qw(name distribution version date dependency status maturity authorized archive)],
        query   => {
            bool => {
                must => [
                    { term => { distribution => $distribution } },
                    { term => { status => 'latest' } },
                ],
                must_not => [
                    { term => { maturity => 'developer' } },
                ],
            },
        },
        sort => [ { date => { order => 'desc' } } ],
    };

    my $res = $http->post(
        "$api_base/release/_search",
        { content => encode_json($query) },
    );
    return unless $res->{success};
    my $obj = eval { decode_json($res->{content}) };
    return unless $obj && ref($obj) eq 'HASH';
    my $hits = $obj->{hits}{hits} || [];
    return unless @$hits;
    return $hits->[0]{_source};
}

sub fetch_dependency_versions {
    my ($module, $distribution) = @_;
    if (!$distribution) {
        my $mod = fetch_module($module);
        $distribution = $mod->{distribution} if $mod;
    }
    return [] unless $distribution;

    my $query = {
        size    => 200,
        _source => [qw(version date distribution maturity status)],
        query   => {
            bool => {
                must => [ { term => { distribution => $distribution } } ],
                must_not => [ { term => { maturity => 'developer' } } ],
            },
        },
        sort => [ { date => { order => 'desc' } } ],
    };

    my $res = $http->post(
        "$api_base/release/_search",
        { content => encode_json($query) },
    );
    return [] unless $res->{success};

    my $obj = eval { decode_json($res->{content}) };
    return [] unless $obj && ref($obj) eq 'HASH';

    my (%seen, @versions);
    for my $hit (@{ $obj->{hits}{hits} || [] }) {
        my $v = normalize_version($hit->{_source}{version});
        next unless defined $v && $v ne '';
        next if $seen{$v}++;
        push @versions, $v;
    }
    return \@versions;
}

sub sample_versions {
    my ($versions, $limit, $mode) = @_;
    my @v = @$versions;
    return @v if @v <= $limit;

    if ($mode eq 'recent') {
        return @v[0 .. $limit - 1];
    }

    # Evenly spaced indices from newest to oldest.
    my %picked;
    my @out;
    for my $i (0 .. $limit - 1) {
        my $idx = int(($i * ($#v)) / ($limit - 1) + 0.5);
        next if $picked{$idx}++;
        push @out, $v[$idx];
    }
    return @out;
}

sub select_dependencies {
    my ($release, $perls) = @_;
    my @out;
    my %seen;

    for my $d (@{ $release->{dependency} || [] }) {
        next unless ref($d) eq 'HASH';
        my $module = $d->{module} // '';
        my $phase  = $d->{phase} // '';
        my $rel    = $d->{relationship} // '';

        next if $module eq '' || $module eq 'perl';
        next unless $rel eq 'requires';
        next if $phase eq 'develop' || $phase =~ /^x_/;
        next if !$include_test_requires && $phase eq 'test';
        next if !$include_build_requires && $phase eq 'build';
        next if $module =~ /::ConfigData\z/;
        next if $seen{$module}++;

        my $is_core_all = 1;
        for my $perl (@$perls) {
            my $first = Module::CoreList->first_release($module);
            if (!defined $first || numeric_perl($first) > numeric_perl($perl)) {
                $is_core_all = 0;
                last;
            }
        }
        next if $is_core_all;

        my $mod = fetch_module($module);
        polite_pause($sleep_ms);

        push @out, {
            module       => $module,
            distribution => $mod ? $mod->{distribution} : undef,
            phase        => $phase,
        };
    }
    return @out;
}

sub build_pairs {
    my @deps = @_;
    my @pairs;
    for my $i (0 .. $#deps) {
        for my $j ($i + 1 .. $#deps) {
            push @pairs, [ $deps[$i], $deps[$j] ];
        }
    }
    return @pairs;
}

sub build_version_combos {
    my ($a, $b, $mode) = @_;
    return () unless @$a && @$b;

    if ($mode eq 'grid') {
        return map {
            my $va = $_;
            map { [ $va, $_ ] } @$b
        } @$a;
    }

    if ($mode eq 'zip') {
        my $n = @$a < @$b ? @$a : @$b;
        return map { [ $a->[$_], $b->[$_] ] } 0 .. $n - 1;
    }

    # Cross mode: corners plus middle/middle, deduplicated.
    my @raw = (
        [ $a->[0],  $b->[0]  ],
        [ $a->[0],  $b->[-1] ],
        [ $a->[-1], $b->[0]  ],
        [ $a->[-1], $b->[-1] ],
        [ $a->[int($#$a / 2)], $b->[int($#$b / 2)] ],
    );
    my (%seen, @out);
    for my $c (@raw) {
        my $key = join "\x1f", @$c;
        next if $seen{$key}++;
        push @out, $c;
    }
    return @out;
}

sub numeric_perl {
    my ($v) = @_;
    $v = "$v";
    $v =~ s/^v//;
    my ($maj, $min) = split /\./, $v, 3;
    $maj ||= 0;
    $min ||= 0;
    return $maj + ($min / 1000);
}

sub normalize_version {
    my ($v) = @_;
    return undef unless defined $v;
    if (ref($v) eq 'HASH' && exists $v->{numified}) {
        return "$v->{numified}";
    }
    return "$v";
}

sub csv_row {
    return join ',', map { csv_quote($_) } @_;
}

sub csv_quote {
    my ($s) = @_;
    $s = '' unless defined $s;
    $s =~ s/"/""/g;
    return qq{"$s"};
}

sub trim {
    my ($s) = @_;
    $s = '' unless defined $s;
    $s =~ s/^\s+//;
    $s =~ s/\s+\z//;
    return $s;
}

sub polite_pause {
    my ($ms) = @_;
    return unless $ms;
    select undef, undef, undef, $ms / 1000;
}

sub sayerr {
    print STDERR @_, "\n";
}

sub usage {
    return <<'USAGE';
Usage:
  build_plan.pl --input modules.txt [options]
  build_plan.pl --packages-index 02packages.details.txt.gz [options]

Important options:
  --output FILE
  --manifest FILE
  --target-modules N
  --module-limit N        Maximum candidate modules examined; 0 means unlimited
  --perl-versions 5.34,5.36,5.38,5.40,5.42
  --max-deps N
  --max-versions N
  --max-pairs N
  --selection-mode ordered|random|balanced
  --version-sampling recent|spread
  --pair-mode zip|grid|cross
  --seed N
  --[no-]include-test-requires
  --[no-]include-build-requires
  --[no-]include-acme
  --[no-]include-alien
USAGE
}

exit main() unless caller;
1;

__RUN_BUILD_PLAN_PERL__
}

run_plan_dedup() {
    perl - "$@" <<'__RUN_PLAN_DEDUP_PERL__'
#!/usr/bin/env perl
use strict;
use warnings;

use Getopt::Long qw(GetOptions);
use File::Basename qw(dirname basename);
use File::Spec;
use Text::ParseWords qw(parse_line);

my $input;
my $output;
my $duplicates_output;
my $help;
my $verbose = 1;

GetOptions(
    'input=s'             => \$input,
    'output=s'            => \$output,
    'duplicates-output=s' => \$duplicates_output,
    'verbose!'            => \$verbose,
    'help'                => \$help,
) or die usage();

die usage() if $help;
die "--input is required\n"  unless defined $input  && length $input;
die "--output is required\n" unless defined $output && length $output;
die "--input and --output must be different files\n"
    if File::Spec->rel2abs($input) eq File::Spec->rel2abs($output);

if (defined $duplicates_output && length $duplicates_output) {
    die "--duplicates-output must differ from --input\n"
        if File::Spec->rel2abs($duplicates_output) eq File::Spec->rel2abs($input);
    die "--duplicates-output must differ from --output\n"
        if File::Spec->rel2abs($duplicates_output) eq File::Spec->rel2abs($output);
}

my @schema = qw(
    base mode module version
    dep_one dep_one_version dep_two dep_two_version
);

open my $in, '<', $input or die "open $input: $!\n";

my $header_line = <$in>;
die "$input is empty\n" unless defined $header_line;
chomp $header_line;
$header_line =~ s/\r\z//;

my @header = parse_csv_line($header_line, 1);
die "expected 8 header columns, found " . scalar(@header) . "\n"
    unless @header == @schema;

for my $i (0 .. $#schema) {
    die "unexpected header column " . ($i + 1)
        . ": expected '$schema[$i]', found '$header[$i]'\n"
        unless $header[$i] eq $schema[$i];
}

my ($out_tmp, $out_fh) = open_temp_output($output);
print {$out_fh} csv_row(@schema), "\n"
    or die "write $out_tmp: $!\n";

my ($dup_tmp, $dup_fh);
if (defined $duplicates_output && length $duplicates_output) {
    ($dup_tmp, $dup_fh) = open_temp_output($duplicates_output);
    print {$dup_fh} csv_row(@schema), "\n"
        or die "write $dup_tmp: $!\n";
}

my %seen;
my $input_rows = 0;
my $unique_rows = 0;
my $duplicate_rows = 0;

while (my $line = <$in>) {
    $input_rows++;
    chomp $line;
    $line =~ s/\r\z//;

    die "blank row at input line " . ($input_rows + 1) . "\n"
        if $line eq '';

    my @fields = parse_csv_line($line, $input_rows + 1);
    die "input line " . ($input_rows + 1)
        . " has " . scalar(@fields) . " columns; expected 8\n"
        unless @fields == @schema;

    my %row;
    @row{@schema} = @fields;
    canonicalize_row(\%row);

    my $key = row_key(\%row);
    if ($seen{$key}++) {
        $duplicate_rows++;
        if ($dup_fh) {
            print {$dup_fh} csv_row(@row{@schema}), "\n"
                or die "write $dup_tmp: $!\n";
        }
        next;
    }

    print {$out_fh} csv_row(@row{@schema}), "\n"
        or die "write $out_tmp: $!\n";
    $unique_rows++;

    if ($verbose && $unique_rows % 100000 == 0) {
        print STDERR "    unique=$unique_rows duplicates=$duplicate_rows\n";
    }
}

close $in or die "close $input: $!\n";
close $out_fh or die "close $out_tmp: $!\n";
rename $out_tmp, $output
    or die "rename $out_tmp to $output: $!\n";

if ($dup_fh) {
    close $dup_fh or die "close $dup_tmp: $!\n";
    rename $dup_tmp, $duplicates_output
        or die "rename $dup_tmp to $duplicates_output: $!\n";
}

print "Input rows:           $input_rows\n";
print "Unique rows written:  $unique_rows\n";
print "Duplicate rows:       $duplicate_rows\n";
print "Output:               $output\n";
print "Duplicates output:    $duplicates_output\n"
    if defined $duplicates_output && length $duplicates_output;

exit 0;

sub parse_csv_line {
    my ($line, $line_number) = @_;
    my @fields = parse_line(',', 0, $line);
    die "could not parse CSV at line $line_number\n"
        unless @fields;
    return @fields;
}

sub canonicalize_row {
    my ($row) = @_;

    for my $name (@schema) {
        $row->{$name} = '' unless defined $row->{$name};
    }

    return unless $row->{mode} eq 'vary-two';

    my $left  = join "\x1f", $row->{dep_one}, $row->{dep_one_version};
    my $right = join "\x1f", $row->{dep_two}, $row->{dep_two_version};

    if ($right lt $left) {
        ($row->{dep_one}, $row->{dep_two})
            = ($row->{dep_two}, $row->{dep_one});
        ($row->{dep_one_version}, $row->{dep_two_version})
            = ($row->{dep_two_version}, $row->{dep_one_version});
    }
}

sub row_key {
    my ($row) = @_;
    return join "\x1e", @{$row}{@schema};
}

sub open_temp_output {
    my ($path) = @_;

    my $dir  = dirname($path);
    my $base = basename($path);
    die "output directory does not exist: $dir\n" unless -d $dir;

    my $tmp = File::Spec->catfile(
        $dir,
        ".$base.tmp.$$",
    );

    open my $fh, '>', $tmp or die "open $tmp: $!\n";
    return ($tmp, $fh);
}

sub csv_row {
    return join ',', map { csv_quote($_) } @_;
}

sub csv_quote {
    my ($value) = @_;
    $value = '' unless defined $value;
    $value =~ s/"/""/g;
    return qq{"$value"};
}

sub usage {
    return <<'USAGE';
Usage:
  plan_dedup.pl --input plan.raw.csv --output plan.unique.csv [options]

Options:
  --input FILE
      Source eight-column Smoker plan CSV.

  --output FILE
      Destination containing the first occurrence of each unique execution row.

  --duplicates-output FILE
      Optional CSV containing rows removed as duplicates.

  --[no-]verbose
      Print periodic progress. Enabled by default.

  --help
      Show this help.

Behavior:
  * preserves the input order of first occurrences
  * validates the exact eight-column Smoker plan schema
  * canonicalizes vary-two dependency ordering before duplicate comparison
  * writes output through a temporary file and renames it on success
USAGE
}

__RUN_PLAN_DEDUP_PERL__
}

run_plan_balance() {
    perl - "$@" <<'__RUN_PLAN_BALANCE_PERL__'
#!/usr/bin/env perl
use strict;
use warnings;

use Getopt::Long qw(GetOptions);
use File::Basename qw(dirname basename);
use File::Spec;
use List::Util qw(shuffle);
use Text::ParseWords qw(parse_line);

my $input;
my $output;
my $target_rows = 0;
my $seed = 20260724;
my $help;

GetOptions(
    'input=s'       => \$input,
    'output=s'      => \$output,
    'target-rows=i' => \$target_rows,
    'seed=i'        => \$seed,
    'help'          => \$help,
) or die usage();

die usage() if $help;
die "--input is required\n"  unless defined $input  && length $input;
die "--output is required\n" unless defined $output && length $output;
die "--target-rows must be >= 0\n" if $target_rows < 0;
die "--input and --output must be different files\n"
    if File::Spec->rel2abs($input) eq File::Spec->rel2abs($output);

my @schema = qw(
    base mode module version
    dep_one dep_one_version dep_two dep_two_version
);

open my $in, '<', $input or die "open $input: $!\n";

my $header_line = <$in>;
die "$input is empty\n" unless defined $header_line;
chomp $header_line;
$header_line =~ s/\r\z//;

my @header = parse_csv_line($header_line, 1);
die "expected 8 header columns, found " . scalar(@header) . "\n"
    unless @header == @schema;

for my $i (0 .. $#schema) {
    die "unexpected header column " . ($i + 1)
        . ": expected '$schema[$i]', found '$header[$i]'\n"
        unless $header[$i] eq $schema[$i];
}

my @rows;
my %seen;
my $line_number = 1;

while (my $line = <$in>) {
    $line_number++;
    chomp $line;
    $line =~ s/\r\z//;

    die "blank row at input line $line_number\n" if $line eq '';

    my @fields = parse_csv_line($line, $line_number);
    die "input line $line_number has " . scalar(@fields)
        . " columns; expected 8\n"
        unless @fields == @schema;

    my %row;
    @row{@schema} = @fields;
    canonicalize_row(\%row);

    my $key = row_key(\%row);
    die "duplicate execution row at input line $line_number\n"
        if $seen{$key}++;

    push @rows, \%row;
}

close $in or die "close $input: $!\n";

die "requested $target_rows rows, but input contains only "
    . scalar(@rows) . "\n"
    if $target_rows && $target_rows > @rows;

srand($seed);

my %bucket;
for my $row (@rows) {
    my $bucket_key = join "\x1f",
        $row->{mode},
        $row->{base},
        $row->{module};

    push @{ $bucket{$bucket_key} }, $row;
}

for my $key (keys %bucket) {
    @{ $bucket{$key} } = shuffle(@{ $bucket{$key} });
}

my @bucket_keys = shuffle(sort keys %bucket);
my @balanced;
my $wanted = $target_rows || scalar(@rows);

while (@balanced < $wanted) {
    my $progress = 0;

    for my $key (@bucket_keys) {
        next unless @{ $bucket{$key} };

        push @balanced, shift @{ $bucket{$key} };
        $progress = 1;

        last if @balanced >= $wanted;
    }

    last unless $progress;
}

die "internal error: selected " . scalar(@balanced)
    . " rows, expected $wanted\n"
    unless @balanced == $wanted;

my ($tmp_path, $out) = open_temp_output($output);

print {$out} csv_row(@schema), "\n"
    or die "write $tmp_path: $!\n";

for my $row (@balanced) {
    print {$out} csv_row(@{$row}{@schema}), "\n"
        or die "write $tmp_path: $!\n";
}

close $out or die "close $tmp_path: $!\n";
rename $tmp_path, $output
    or die "rename $tmp_path to $output: $!\n";

print "Input rows:          ", scalar(@rows), "\n";
print "Balance buckets:     ", scalar(keys %bucket), "\n";
print "Rows written:        ", scalar(@balanced), "\n";
print "Rows omitted by cap: ", scalar(@rows) - scalar(@balanced), "\n";
print "Seed:                $seed\n";
print "Output:              $output\n";

exit 0;

sub parse_csv_line {
    my ($line, $number) = @_;
    my @fields = parse_line(',', 0, $line);
    die "could not parse CSV at line $number\n" unless @fields;
    return @fields;
}

sub canonicalize_row {
    my ($row) = @_;

    for my $name (@schema) {
        $row->{$name} = '' unless defined $row->{$name};
    }

    return unless $row->{mode} eq 'vary-two';

    my $left  = join "\x1f", $row->{dep_one}, $row->{dep_one_version};
    my $right = join "\x1f", $row->{dep_two}, $row->{dep_two_version};

    if ($right lt $left) {
        ($row->{dep_one}, $row->{dep_two})
            = ($row->{dep_two}, $row->{dep_one});
        ($row->{dep_one_version}, $row->{dep_two_version})
            = ($row->{dep_two_version}, $row->{dep_one_version});
    }
}

sub row_key {
    my ($row) = @_;
    return join "\x1e", @{$row}{@schema};
}

sub open_temp_output {
    my ($path) = @_;

    my $dir  = dirname($path);
    my $base = basename($path);
    die "output directory does not exist: $dir\n" unless -d $dir;

    my $tmp = File::Spec->catfile($dir, ".$base.tmp.$$");
    open my $fh, '>', $tmp or die "open $tmp: $!\n";

    return ($tmp, $fh);
}

sub csv_row {
    return join ',', map { csv_quote($_) } @_;
}

sub csv_quote {
    my ($value) = @_;
    $value = '' unless defined $value;
    $value =~ s/"/""/g;
    return qq{"$value"};
}

sub usage {
    return <<'USAGE';
Usage:
  plan_balance.pl --input plan.unique.csv --output plan.balanced.csv [options]

Options:
  --input FILE
      Source eight-column Smoker plan CSV. Input rows must already be unique.

  --output FILE
      Destination CSV in balanced round-robin order.

  --target-rows N
      Optional balanced subset size. Zero writes all rows.
      Default: 0.

  --seed N
      Random seed controlling bucket and within-bucket order.
      Default: 20260724.

  --help
      Show this help.

Balancing:
  Rows are placed into buckets keyed by:
      mode + Perl base + target module

  Output is selected round-robin across those buckets. This spreads modes,
  Perl images, and target modules through the plan instead of leaving long
  runs of similar rows.
USAGE
}

__RUN_PLAN_BALANCE_PERL__
}

run_plan_shuffle() {
    perl - "$@" <<'__RUN_PLAN_SHUFFLE_PERL__'
#!/usr/bin/env perl
use strict;
use warnings;

use Getopt::Long qw(GetOptions);
use File::Basename qw(dirname basename);
use File::Spec;
use List::Util qw(shuffle);
use Text::ParseWords qw(parse_line);

my $input;
my $output;
my $seed = time;
my $help;

GetOptions(
    'input=s'  => \$input,
    'output=s' => \$output,
    'seed=i'   => \$seed,
    'help'     => \$help,
) or die usage();

die usage() if $help;
die "--input is required\n"  unless defined $input  && length $input;
die "--output is required\n" unless defined $output && length $output;
die "--input and --output must be different files\n"
    if File::Spec->rel2abs($input) eq File::Spec->rel2abs($output);

my @schema = qw(
    base mode module version
    dep_one dep_one_version dep_two dep_two_version
);

open my $in, '<', $input or die "open $input: $!\n";

my $header_line = <$in>;
die "$input is empty\n" unless defined $header_line;
chomp $header_line;
$header_line =~ s/\r\z//;

my @header = parse_csv_line($header_line, 1);
die "expected 8 header columns, found " . scalar(@header) . "\n"
    unless @header == @schema;

for my $i (0 .. $#schema) {
    die "unexpected header column " . ($i + 1)
        . ": expected '$schema[$i]', found '$header[$i]'\n"
        unless $header[$i] eq $schema[$i];
}

my @rows;
my $line_number = 1;

while (my $line = <$in>) {
    $line_number++;
    chomp $line;
    $line =~ s/\r\z//;

    die "blank row at input line $line_number\n" if $line eq '';

    my @fields = parse_csv_line($line, $line_number);
    die "input line $line_number has " . scalar(@fields)
        . " columns; expected 8\n"
        unless @fields == @schema;

    push @rows, \@fields;
}

close $in or die "close $input: $!\n";

srand($seed);
@rows = shuffle(@rows);

my ($tmp_path, $out) = open_temp_output($output);

print {$out} csv_row(@schema), "\n"
    or die "write $tmp_path: $!\n";

for my $row (@rows) {
    print {$out} csv_row(@$row), "\n"
        or die "write $tmp_path: $!\n";
}

close $out or die "close $tmp_path: $!\n";
rename $tmp_path, $output
    or die "rename $tmp_path to $output: $!\n";

print "Input rows:     ", scalar(@rows), "\n";
print "Rows shuffled:  ", scalar(@rows), "\n";
print "Seed:           $seed\n";
print "Output:         $output\n";

exit 0;

sub parse_csv_line {
    my ($line, $line_number) = @_;
    my @fields = parse_line(',', 0, $line);
    die "could not parse CSV at line $line_number\n"
        unless @fields;
    return @fields;
}

sub open_temp_output {
    my ($path) = @_;

    my $dir  = dirname($path);
    my $base = basename($path);
    die "output directory does not exist: $dir\n" unless -d $dir;

    my $tmp = File::Spec->catfile($dir, ".$base.tmp.$$");
    open my $fh, '>', $tmp or die "open $tmp: $!\n";

    return ($tmp, $fh);
}

sub csv_row {
    return join ',', map { csv_quote($_) } @_;
}

sub csv_quote {
    my ($value) = @_;
    $value = '' unless defined $value;
    $value =~ s/"/""/g;
    return qq{"$value"};
}

sub usage {
    return <<'USAGE';
Usage:
  plan_shuffle.pl --input plan.unique.csv --output plan.shuffled.csv [options]

Options:
  --input FILE
      Source eight-column Smoker plan CSV.

  --output FILE
      Destination CSV containing the same rows in shuffled order.

  --seed N
      Random seed. Supplying the same seed and input reproduces the same order.
      Default: current Unix time.

  --help
      Show this help.

Behavior:
  * preserves the exact eight-column Smoker plan schema
  * validates every input row
  * preserves all rows without adding or removing any
  * writes through a temporary file and renames it on success
USAGE
}

__RUN_PLAN_SHUFFLE_PERL__
}

run_plan_analyze() {
    perl - "$@" <<'__RUN_PLAN_ANALYZE_PERL__'
#!/usr/bin/env perl
use strict;
use warnings;

use Getopt::Long qw(GetOptions);
use JSON::PP ();
use Text::ParseWords qw(parse_line);

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

open my $in, '<', $input or die "open $input: $!\n";

my $header_line = <$in>;
die "$input is empty\n" unless defined $header_line;
chomp $header_line;
$header_line =~ s/\r\z//;

my @header = parse_csv_line($header_line, 1);
die "expected 8 header columns, found " . scalar(@header) . "\n"
    unless @header == @schema;

for my $i (0 .. $#schema) {
    die "unexpected header column " . ($i + 1)
        . ": expected '$schema[$i]', found '$header[$i]'\n"
        unless $header[$i] eq $schema[$i];
}

my $rows = 0;
my $duplicate_rows = 0;

my (%seen_row, %by_mode, %by_base, %by_module, %dependency_frequency);
my (%module_versions, %dependency_versions);

my $line_number = 1;

while (my $line = <$in>) {
    $line_number++;
    chomp $line;
    $line =~ s/\r\z//;

    die "blank row at input line $line_number\n" if $line eq '';

    my @fields = parse_csv_line($line, $line_number);
    die "input line $line_number has " . scalar(@fields)
        . " columns; expected 8\n"
        unless @fields == @schema;

    my %row;
    @row{@schema} = @fields;
    canonicalize_row(\%row);

    $rows++;

    my $key = row_key(\%row);
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

close $in or die "close $input: $!\n";

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

sub parse_csv_line {
    my ($line, $number) = @_;
    my @fields = parse_line(',', 0, $line);
    die "could not parse CSV at line $number\n" unless @fields;
    return @fields;
}

sub canonicalize_row {
    my ($row) = @_;

    for my $name (@schema) {
        $row->{$name} = '' unless defined $row->{$name};
    }

    return unless $row->{mode} eq 'vary-two';

    my $left  = join "\x1f", $row->{dep_one}, $row->{dep_one_version};
    my $right = join "\x1f", $row->{dep_two}, $row->{dep_two_version};

    if ($right lt $left) {
        ($row->{dep_one}, $row->{dep_two})
            = ($row->{dep_two}, $row->{dep_one});
        ($row->{dep_one_version}, $row->{dep_two_version})
            = ($row->{dep_two_version}, $row->{dep_one_version});
    }
}

sub row_key {
    my ($row) = @_;
    return join "\x1e", @{$row}{@schema};
}

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

__RUN_PLAN_ANALYZE_PERL__
}

while (($#)); do
    case "$1" in
        --packages-index)
            (($# >= 2)) || die "--packages-index requires a value"
            source_packages_index=$2
            shift 2
            ;;
        --input)
            (($# >= 2)) || die "--input requires a value"
            module_input=$2
            shift 2
            ;;
        --prefix)
            (($# >= 2)) || die "--prefix requires a value"
            prefix=$2
            shift 2
            ;;
        --target-modules)
            (($# >= 2)) || die "--target-modules requires a value"
            target_modules=$2
            shift 2
            ;;
        --module-limit)
            (($# >= 2)) || die "--module-limit requires a value"
            module_limit=$2
            shift 2
            ;;
        --perl-versions)
            (($# >= 2)) || die "--perl-versions requires a value"
            perl_versions=$2
            shift 2
            ;;
        --max-deps)
            (($# >= 2)) || die "--max-deps requires a value"
            max_deps=$2
            shift 2
            ;;
        --max-versions)
            (($# >= 2)) || die "--max-versions requires a value"
            max_versions=$2
            shift 2
            ;;
        --max-pairs)
            (($# >= 2)) || die "--max-pairs requires a value"
            max_pairs=$2
            shift 2
            ;;
        --selection-mode)
            (($# >= 2)) || die "--selection-mode requires a value"
            selection_mode=$2
            shift 2
            ;;
        --version-sampling)
            (($# >= 2)) || die "--version-sampling requires a value"
            version_sampling=$2
            shift 2
            ;;
        --pair-mode)
            (($# >= 2)) || die "--pair-mode requires a value"
            pair_mode=$2
            shift 2
            ;;
        --seed)
            (($# >= 2)) || die "--seed requires a value"
            seed=$2
            shift 2
            ;;
        --sleep-ms)
            (($# >= 2)) || die "--sleep-ms requires a value"
            sleep_ms=$2
            shift 2
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            die "unknown option: $1"
            ;;
    esac
done

printf '\n[0/6] Cleaning previous plan artifacts\n'
clean_plan_workspace

if [[ -n $module_input ]]; then
    packages_index=""
else
    [[ -f $source_packages_index ]]         || die "packages index not found: $source_packages_index"

    copied_index="$SCRIPT_DIR/02packages.details.txt.gz"
    randomized_index="$SCRIPT_DIR/$randomized_index_name"

    printf '\n[1/6] Preparing randomized packages index\n'
    cp -f -- "$source_packages_index" "$copied_index"

    gzip -dc -- "$copied_index" |
    perl -e '
        use strict;
        use warnings;
        use List::Util qw(shuffle);

        my @header;
        my @rows;
        my $in_body = 0;

        while (my $line = <STDIN>) {
            if (!$in_body) {
                push @header, $line;
                $in_body = 1 if $line =~ /^\s*$/;
                next;
            }

            push @rows, $line if $line !~ /^\s*$/;
        }

        print @header;
        print shuffle(@rows);
    ' |
    gzip -c > "$randomized_index"

    packages_index="$randomized_index"

    printf 'Copied index:          %s\n' "$copied_index"
    printf 'Randomized index:      %s\n' "$randomized_index"
fi

for command in gzip perl; do
    command -v "$command" >/dev/null 2>&1         || die "required command not found: $command"
done

if [[ -n $module_input ]]; then
    [[ -f $module_input ]] || die "module list not found: $module_input"
    source_args=(--input "$module_input")
else
    [[ -f $packages_index ]] || die "randomized packages index not found: $packages_index"
    source_args=(--packages-index "$packages_index")
fi

raw="${prefix}.raw.csv"
manifest="${prefix}.manifest.json"
unique="${prefix}.unique.csv"
duplicates="${prefix}.duplicates.csv"
balanced="${prefix}.balanced.csv"
final="${prefix}.final.csv"
analysis_txt="${prefix}.analysis.txt"
analysis_json="${prefix}.analysis.json"

printf '\n[2/6] Building raw plan\n'
run_build_plan \
    "${source_args[@]}" \
    --output "$raw" \
    --manifest "$manifest" \
    --target-modules "$target_modules" \
    --module-limit "$module_limit" \
    --perl-versions "$perl_versions" \
    --max-deps "$max_deps" \
    --max-versions "$max_versions" \
    --max-pairs "$max_pairs" \
    --selection-mode "$selection_mode" \
    --version-sampling "$version_sampling" \
    --pair-mode "$pair_mode" \
    --seed "$seed" \
    --sleep-ms "$sleep_ms"

printf '\n[3/6] Deduplicating plan\n'
run_plan_dedup \
    --input "$raw" \
    --output "$unique" \
    --duplicates-output "$duplicates"

printf '\n[4/6] Balancing plan\n'
run_plan_balance \
    --input "$unique" \
    --output "$balanced" \
    --seed "$seed"

printf '\n[5/6] Shuffling balanced plan\n'
run_plan_shuffle \
    --input "$balanced" \
    --output "$final" \
    --seed "$seed"

printf '\n[6/6] Analyzing final plan\n'
run_plan_analyze \
    --input "$final" \
    --output "$analysis_txt" \
    --json-output "$analysis_json"

raw_rows=$(($(wc -l < "$raw") - 1))
unique_rows=$(($(wc -l < "$unique") - 1))
balanced_rows=$(($(wc -l < "$balanced") - 1))
final_rows=$(($(wc -l < "$final") - 1))
duplicate_rows=$(($(wc -l < "$duplicates") - 1))
final_unique=$(tail -n +2 "$final" | sort -u | wc -l)

planned_modules=$(perl -MJSON::PP -0777 -e '
    my $m = decode_json(<>);
    print $m->{planned_modules} // 0;
' "$manifest")

manifest_status=$(perl -MJSON::PP -0777 -e '
    my $m = decode_json(<>);
    print $m->{status} // "";
' "$manifest")

[[ $planned_modules -eq $target_modules ]] \
    || die "planned module count is $planned_modules; expected $target_modules"
[[ $manifest_status == complete ]] \
    || die "builder manifest status is '$manifest_status', expected complete"
[[ $raw_rows -gt 0 ]] \
    || die "raw plan contains no data rows"
[[ $unique_rows -eq $raw_rows ]] \
    || die "unique row count $unique_rows differs from raw count $raw_rows"
[[ $balanced_rows -eq $unique_rows ]] \
    || die "balanced row count $balanced_rows differs from unique count $unique_rows"
[[ $final_rows -eq $balanced_rows ]] \
    || die "final row count $final_rows differs from balanced count $balanced_rows"
[[ $final_unique -eq $final_rows ]] \
    || die "final plan contains duplicate rows"

printf '\nPipeline validation: PASS\n'
printf 'Planned modules:       %d\n' "$planned_modules"
printf 'Raw rows:             %d\n' "$raw_rows"
printf 'Duplicate rows:       %d\n' "$duplicate_rows"
printf 'Unique rows:          %d\n' "$unique_rows"
printf 'Balanced rows:        %d\n' "$balanced_rows"
printf 'Final rows:           %d\n' "$final_rows"
printf 'Final unique rows:    %d\n' "$final_unique"
printf 'Final plan:           %s\n' "$final"
printf 'Analysis:             %s\n' "$analysis_txt"
