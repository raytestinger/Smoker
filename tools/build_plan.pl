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
