package Smoker::Analysis;
use strict;
use warnings;

use Exporter 'import';
our @EXPORT_OK = qw(analyze_batch classify_run);

use File::Spec;
use File::Path qw(make_path);
use Text::CSV;

sub analyze_batch {
    my (%opt) = @_;

    my $batch_dir = $opt{batch_dir} or die "missing batch_dir\n";
    my $summary   = File::Spec->catfile($batch_dir, 'summary.csv');
    die "missing summary.csv\n" unless -f $summary;

    my $analysis_dir = File::Spec->catdir($batch_dir, 'analysis');
    my $examples_dir = File::Spec->catdir($analysis_dir, 'examples');

    make_path($analysis_dir, $examples_dir);

    my $rows = _read_summary($summary);
    my @fail = grep { ($_->{status} || '') ne 'PASS' } @$rows;

    my (@classified, %stage, %subtype, %module);

    for my $row (@fail) {
        my $class = classify_run(
            run_dir   => $row->{run_dir},
            row       => $row,
            batch_dir => $batch_dir,
        );

        my %out = (%$row, %$class);
        $out{run_dir} = $class->{resolved_run_dir};

        push @classified, \%out;

        $stage{ $class->{stage} }++;
        $subtype{ $class->{subtype} }++;
        $module{ $row->{module} || 'UNKNOWN' }++;

        _write_example(
            examples_dir => $examples_dir,
            subtype      => $class->{subtype},
            row          => \%out,
        );
    }

    _write_tsv("$analysis_dir/classifications.tsv", \@classified, [
        qw(batch base mode module version status rc elapsed_s run_dir note
           stage subtype confidence primary_reason evidence)
    ]);

    _write_counts("$analysis_dir/counts_by_stage.tsv",   'stage',   \%stage);
    _write_counts("$analysis_dir/counts_by_subtype.tsv", 'subtype', \%subtype);
    _write_counts("$analysis_dir/by_module.tsv",         'module',  \%module);

    return {
        batch_dir    => $batch_dir,
        analysis_dir => $analysis_dir,
        fail_rows    => scalar @fail,
    };
}

sub classify_run {
    my (%opt) = @_;

    my $run_dir   = $opt{run_dir} || '';
    my $row       = $opt{row} || {};
    my $batch_dir = $opt{batch_dir} || '';

    $run_dir = _resolve_run_dir($run_dir, $batch_dir);

    my $build = File::Spec->catfile($run_dir, 'build.log');
    my $err   = File::Spec->catfile($run_dir, 'run.err');

    my $build_lines = _read_lines($build);
    my $err_lines   = _read_lines($err);

    my ($stage, $sub, $conf, $reason, $evidence) =
        _classify_lines($build_lines, $err_lines, $row);

    return {
        stage            => $stage,
        subtype          => $sub,
        confidence       => $conf,
        primary_reason   => $reason,
        evidence         => $evidence,
        resolved_run_dir => $run_dir,
    };
}

sub _classify_lines {
    my ($build, $err, $row) = @_;

    my @all = (
        map { ['build.log', $_ + 1, $build->[$_]] } 0 .. $#$build,
        map { ['run.err',   $_ + 1, $err->[$_]]   } 0 .. $#$err,
    );

    for (my $i = $#all; $i >= 0; $i--) {
        my ($src, $ln, $line) = @{ $all[$i] };
        next unless defined $line;

        my $t = $line;
        $t =~ s/\r$//;

        if ($t =~ /Unknown option:\s*reporter/i) {
            return ('CONFIGURE', 'environment_contamination', 'high',
                'cpanm environment contamination',
                "$src:$ln: $t");
        }

        if ($t =~ /\[inner\]\s+failed applying (?:pin|dependency version)/i) {
            return ('INSTALL', 'dependency_version_unavailable', 'high',
                'requested dependency version could not be installed',
                "$src:$ln: $t");
        }

        if ($t =~ /\[inner\]\s+dependency version unavailable for /i) {
            return ('INSTALL', 'dependency_version_unavailable', 'high',
                'requested dependency version is unavailable',
                "$src:$ln: $t");
        }

        if ($t =~ /\[inner\]\s+refusing to continue because requested dependency version is unavailable/i) {
            return ('INSTALL', 'dependency_version_unavailable', 'high',
                'requested dependency version is unavailable',
                "$src:$ln: $t");
        }

        # Backward compatibility for older logs generated before the user-facing
        # wording changed from "pin" to "dependency version".
        if ($t =~ /\[inner\]\s+pin mismatch for /i ||
            $t =~ /\[inner\]\s+refusing to continue because requested pin did not stick/i) {
            return ('INSTALL', 'dependency_version_unavailable', 'high',
                'requested dependency version is unavailable',
                "$src:$ln: $t");
        }

        if ($t =~ /doesn't satisfy ==/) {
            return ('INSTALL', 'dependency_version_unavailable', 'high',
                'requested dependency version is unavailable',
                "$src:$ln: $t");
        }

        if ($t =~ /Can't locate .*? in \@INC/) {
            return ('INSTALL', 'missing_prereq', 'high',
                'module missing from @INC',
                "$src:$ln: $t");
        }

        if ($t =~ /Configure failed|Makefile\.PL .* NO|Build\.PL .* NO/i) {
            return ('CONFIGURE', 'configure_failure', 'high',
                'configure phase failed',
                "$src:$ln: $t");
        }

        if ($t =~ /No such file or directory|cannot find -l|pkg-config|compiler cannot create/i) {
            return ('BUILD', 'external_dependency_missing', 'high',
                'missing system dependency',
                "$src:$ln: $t");
        }

        if ($t =~ /undefined reference|ld returned|gcc.*error|make: \*\*\*/) {
            return ('BUILD', 'build_compile_failure', 'high',
                'compile/link failure',
                "$src:$ln: $t");
        }

        if ($t =~ /Failed test|Result: FAIL|No subtests run/) {
            return ('TEST', 'test_failure', 'high',
                'test suite failure',
                "$src:$ln: $t");
        }

        if ($t =~ /Installing the dependencies failed: Module '.*?' is not installed/) {
            return ('INSTALL', 'missing_prereq', 'high',
                'dependency not installed',
                "$src:$ln: $t");
        }

        if ($t =~ /!\s+Installing\s+([A-Za-z0-9_:]+)\s+failed/) {
            my $failed = $1;
            my $target = $row->{module} || '';

            if ($failed =~ /^Alien::/) {
                return ('BUILD', 'external_dependency_failure', 'high',
                    'system or native dependency failure (Alien module)',
                    "$src:$ln: $t");
            }

            if ($failed eq $target) {
                return ('INSTALL', 'target_install_failure', 'high',
                    'target module failed to install',
                    "$src:$ln: $t");
            }

            return ('INSTALL', 'dependency_install_failure', 'high',
                'dependency failed to install',
                "$src:$ln: $t");
        }
    }

    if (($row->{mode} || '') eq 'vary-two') {
        return ('UNKNOWN', 'interaction_failure', 'low',
            'vary-two interaction failure', '');
    }

    return ('UNKNOWN', 'unknown', 'low',
        'no signature matched', '');
}

sub _resolve_run_dir {
    my ($run, $batch) = @_;
    return $run if $run && -d $run;

    return $run unless $run && $batch;

    my ($base) = $run =~ /([^\/]+)$/;
    my $cand = File::Spec->catdir($batch, 'runs', $base);

    return -d $cand ? $cand : $run;
}

sub _read_summary {
    my ($path) = @_;

    open my $fh, '<', $path or die $!;
    my $csv = Text::CSV->new({ binary => 1, auto_diag => 1 });

    my $hdr = $csv->getline($fh);
    my @cols = @$hdr;

    my @rows;
    while (my $r = $csv->getline($fh)) {
        my %h;
        @h{@cols} = @$r;
        $h{module} ||= $h{module_name} || '';
        push @rows, \%h;
    }

    close $fh;
    return \@rows;
}

sub _write_tsv {
    my ($f, $rows, $cols) = @_;
    open my $fh, '>', $f or die $!;

    print $fh join("\t", @$cols), "\n";

    for my $row (@$rows) {
        my @vals = map {
            defined $row->{$_} ? $row->{$_} : ''
        } @$cols;

        s/\r?\n/ /g for @vals;
        print $fh join("\t", @vals), "\n";
    }

    close $fh;
}

sub _write_counts {
    my ($f, $name, $h) = @_;
    open my $fh, '>', $f or die $!;
    print $fh "$name\tcount\n";
    for (sort { $h->{$b} <=> $h->{$a} } keys %$h) {
        print $fh "$_\t$h->{$_}\n";
    }
    close $fh;
}

sub _write_example {
    my (%o) = @_;
    my $dir = "$o{examples_dir}/$o{subtype}";
    make_path($dir);

    my $m = $o{row}{module} || 'UNKNOWN';
    $m =~ s/::/_/g;
    my $file = "$dir/${m}.txt";

    return if -e $file;

    open my $fh, '>', $file or die $!;
    print $fh "$o{row}{evidence}\n";
    close $fh;
}

sub _read_lines {
    my ($p) = @_;
    return [] unless -f $p;
    open my $fh, '<', $p or return [];
    my @l = <$fh>;
    close $fh;
    chomp @l;
    s/\r$// for @l;
    return \@l;
}

1;
