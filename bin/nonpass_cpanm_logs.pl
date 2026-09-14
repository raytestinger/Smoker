#!/usr/bin/env perl

use strict;
use warnings;

use File::Basename qw(basename);
use File::Spec;
use Text::CSV;

# ----------------------------------------------------------------------
# nonpass_cpanm_logs.pl
#
# Review every non-PASS row in a Smoker batch.
#
# Usage:
#
#   nonpass_cpanm_logs.pl BATCH_DIRECTORY
#
# The batch directory must contain:
#
#   summary.csv
#   runs/
#
# For each non-PASS run, diagnostic sources are examined in this order:
#
#   runs/<run_number>/run.out
#   runs/<run_number>/unavailable.note
#   runs/<run_number>/reports/cpanm_work_build.log
#   runs/<run_number>/build.log
#   runs/<run_number>/run.err
#
# The first useful diagnostic is printed. Absolute run_dir values copied
# from another location are relocated to BATCH_DIRECTORY/runs/<run_number>.
#
# The report contains:
#
#   * one compact section for each non-PASS run;
#   * the terminal failure section or cpanm failure text;
#   * PASS and non-PASS totals;
#   * counts of repeated diagnostic patterns.
#
# The caller may redirect standard output to batch_review.txt.
# ----------------------------------------------------------------------

my $batch_dir = shift @ARGV
    or die usage();

@ARGV == 0
    or die usage();

-d $batch_dir
    or die "Batch directory does not exist: $batch_dir\n";

my $summary_file = File::Spec->catfile(
    $batch_dir,
    'summary.csv',
);

-f $summary_file
    or die "Cannot find summary.csv: $summary_file\n";

open my $summary_fh, '<', $summary_file
    or die "Cannot open $summary_file: $!\n";

my $csv = Text::CSV->new({
    binary              => 1,
    auto_diag           => 1,
    allow_loose_quotes  => 1,
    allow_loose_escapes => 1,
}) or die "Cannot create CSV parser\n";

my $header = $csv->getline($summary_fh)
    or die "Cannot read the header from $summary_file\n";

$csv->column_names(@{$header});

my $pass_count               = 0;
my $nonpass_count            = 0;
my $missing_count            = 0;
my $empty_count              = 0;
my $terminal_section_count   = 0;
my $cpanm_fallback_count     = 0;
my $no_diagnostic_count      = 0;
my %diagnostic_patterns;

while (my $row = $csv->getline_hr($summary_fh)) {
    my $status  = trim($row->{status}  // '');
    my $run_dir = trim($row->{run_dir} // '');

    if ($status eq 'PASS') {
        ++$pass_count;
        next;
    }

    ++$nonpass_count;

    $status ne ''
        or die "A non-PASS row in $summary_file has an empty status field\n";

    $run_dir ne ''
        or die "A $status row in $summary_file has an empty run_dir field\n";

    my $resolved_run_dir = resolve_run_dir(
        batch_dir => $batch_dir,
        run_dir   => $run_dir,
    );

    -d $resolved_run_dir
        or die "Cannot find run directory: $resolved_run_dir\n";

    my $run_number = basename($resolved_run_dir);

    my @candidates = (
        {
            path  => File::Spec->catfile($resolved_run_dir, 'run.out'),
            label => 'run.out',
            kind  => 'terminal',
        },
        {
            path  => File::Spec->catfile($resolved_run_dir, 'unavailable.note'),
            label => 'unavailable.note',
            kind  => 'note',
        },
        {
            path  => File::Spec->catfile(
                $resolved_run_dir,
                'reports',
                'cpanm_work_build.log',
            ),
            label => File::Spec->catfile('reports', 'cpanm_work_build.log'),
            kind  => 'cpanm',
        },
        {
            path  => File::Spec->catfile($resolved_run_dir, 'build.log'),
            label => 'build.log',
            kind  => 'build',
        },
        {
            path  => File::Spec->catfile($resolved_run_dir, 'run.err'),
            label => 'run.err',
            kind  => 'stderr',
        },
    );

    my $saw_existing = 0;
    my $saw_nonempty = 0;
    my $selected;

    CANDIDATE:
    for my $candidate (@candidates) {
        next if !-e $candidate->{path};

        $saw_existing = 1;

        next if !-f $candidate->{path};
        next if !-s $candidate->{path};

        $saw_nonempty = 1;

        my $lines = read_lines($candidate->{path});
        my $diagnostic = extract_diagnostic(
            lines  => $lines,
            status => $status,
            kind   => $candidate->{kind},
        );

        if (@{$diagnostic}) {
            $selected = {
                %{$candidate},
                diagnostic => $diagnostic,
            };
            last CANDIDATE;
        }
    }

    print "\n", '=' x 78, "\n";
    print "Run $run_number\n";
    print "Status : $status\n";

    if (!$selected) {
        if (!$saw_existing) {
            print "Log    : none\n";
            print '-' x 78, "\n";
            print "No diagnostic source files exist for this run.\n";
            ++$missing_count;
        }
        elsif (!$saw_nonempty) {
            print "Log    : none\n";
            print '-' x 78, "\n";
            print "Available diagnostic files are empty or are not regular files.\n";
            ++$empty_count;
        }
        else {
            print "Log    : no usable diagnostic\n";
            print '-' x 78, "\n";
            print "No recognized terminal, unavailable, or cpanm diagnostic was found.\n";
            ++$no_diagnostic_count;
        }

        ++$diagnostic_patterns{'No diagnostic found'};
        next;
    }

    print "Log    : $selected->{label}\n";
    print '-' x 78, "\n";
    my $display_diagnostic = normalize_diagnostic(
        $selected->{diagnostic},
    );

    print @{$display_diagnostic};

    print "\n"
        if @{$selected->{diagnostic}}
        && $selected->{diagnostic}[-1] !~ /\n\z/;

    if (
        $selected->{kind} eq 'terminal'
        || $selected->{kind} eq 'build'
    ) {
        ++$terminal_section_count;
    }
    else {
        ++$cpanm_fallback_count;
    }

    my $pattern = diagnostic_pattern(
        status     => $status,
        diagnostic => $display_diagnostic,
    );

    ++$diagnostic_patterns{$pattern};
}

close $summary_fh
    or die "Cannot close $summary_file: $!\n";

print "\n", '=' x 78, "\n";
printf "PASS results                 : %d\n", $pass_count;
printf "Non-PASS results reviewed    : %d\n", $nonpass_count;
printf "Missing log files            : %d\n", $missing_count;
printf "Empty log files              : %d\n", $empty_count;
printf "Terminal diagnostics selected: %d\n", $terminal_section_count;
printf "Other diagnostics selected   : %d\n", $cpanm_fallback_count;
printf "No diagnostic found          : %d\n", $no_diagnostic_count;

if (%diagnostic_patterns) {
    print "\nRepeated diagnostic patterns:\n";

    for my $pattern (
        sort {
            $diagnostic_patterns{$b} <=> $diagnostic_patterns{$a}
                || $a cmp $b
        } keys %diagnostic_patterns
    ) {
        printf "  %5d  %s\n",
            $diagnostic_patterns{$pattern},
            $pattern;
    }
}

print '=' x 78, "\n";

exit 0;


sub resolve_run_dir {
    my (%args) = @_;

    my $batch_dir = $args{batch_dir};
    my $run_dir   = $args{run_dir};

    return $run_dir
        if -d $run_dir;

    my $run_number = basename($run_dir);

    my $relocated = File::Spec->catdir(
        $batch_dir,
        'runs',
        $run_number,
    );

    return $relocated
        if -d $relocated;

    if (!File::Spec->file_name_is_absolute($run_dir)) {
        my $relative = File::Spec->catdir($batch_dir, $run_dir);

        return $relative
            if -d $relative;
    }

    return $relocated;
}


sub read_lines {
    my ($path) = @_;

    open my $fh, '<', $path
        or die "Cannot open $path: $!\n";

    my @lines = <$fh>;

    close $fh
        or die "Cannot close $path: $!\n";

    return \@lines;
}


sub extract_diagnostic {
    my (%args) = @_;

    my $lines  = $args{lines};
    my $status = $args{status};
    my $kind   = $args{kind};

    if ($kind eq 'note') {
        my @useful = grep { trim($_) ne '' } @{$lines};

        return \@useful;
    }

    if ($kind eq 'terminal' || $kind eq 'build') {
        my $terminal = extract_terminal_section($lines);

        return $terminal
            if @{$terminal};
    }

    if ($kind eq 'cpanm' || $kind eq 'build' || $kind eq 'stderr') {
        my $cpanm = extract_cpanm_failure($lines);

        return $cpanm
            if @{$cpanm};
    }

    if ($status eq 'UNAVAILABLE') {
        my $unavailable = extract_unavailable_section($lines);

        return $unavailable
            if @{$unavailable};
    }

    return [];
}


sub extract_terminal_section {
    my ($lines) = @_;

    # Accept both current terminology and legacy logs produced before
    # "pin mismatch" was renamed to "dependency version mismatch".
    my $start;

    for my $index (0 .. $#{$lines}) {
        if (
            $lines->[$index] =~
                /^\s*\[inner\]\s+(?:
                    (?:dependency\ version|pin)\ mismatch\b
                    |
                    .*\b(?:failed|failure|unavailable)\b
                )/i
        ) {
            $start = $index;
        }
    }

    return []
        if !defined $start;

    my @section;

    for my $index ($start .. $#{$lines}) {
        my $line = $lines->[$index];

        push @section, $line;

        last
            if $line =~ /^\s*\[inner\]\s+rc=\d+\s*$/;
    }

    return \@section;
}


sub extract_unavailable_section {
    my ($lines) = @_;

    my $start;

    for my $index (0 .. $#{$lines}) {
        if (
            $lines->[$index] =~
                /^\s*\[inner\]\s+.*(?:unavailable note|unavailable)\b/i
        ) {
            $start = $index;
        }
    }

    return []
        if !defined $start;

    my @section;

    for my $index ($start .. $#{$lines}) {
        my $line = $lines->[$index];

        push @section, $line;

        last
            if $line =~ /^\s*\[inner\]\s+rc=111\s*$/;
    }

    return \@section;
}


sub extract_cpanm_failure {
    my ($lines) = @_;

    my @error_indexes;

    for my $index (0 .. $#{$lines}) {
        push @error_indexes, $index
            if is_cpanm_error_line($lines->[$index]);
    }

    return []
        if !@error_indexes;

    my $error_index = best_cpanm_error_index(
        lines         => $lines,
        error_indexes => \@error_indexes,
    );

    my $start = $error_index;
    my $end   = $error_index + 12;

    $end = $#{$lines}
        if $end > $#{$lines};

    return [
        @{$lines}[$start .. $end]
    ];
}


sub best_cpanm_error_index {
    my (%args) = @_;

    my $lines         = $args{lines};
    my $error_indexes = $args{error_indexes};

    for my $index (reverse @{$error_indexes}) {
        my $line = $lines->[$index];

        return $index
            if $line =~ /^\s*\[inner\]\s+.*\b(?:
                mismatch
                |
                verification\s+failed
                |
                failed\s+applying
                |
                refusing\s+to\s+continue
            )\b/ix;

        return $index
            if $line =~ /\bPermission\s+denied\b/i;

        return $index
            if $line =~ /^\s*!\s+Installing\b.*\bfailed\b/i;

        return $index
            if $line =~ /^\s*!\s+Finding\b.*\bfailed\b/i;

        return $index
            if $line =~ /^\s*(?:make|gmake):\s+\*\*\*/i;

        return $index
            if $line =~ /^\s*(?:error|fatal)\b/i;
    }

    return $error_indexes->[-1];
}


sub is_cpanm_error_line {
    my ($line) = @_;

    return 1 if $line =~ /^\s*!/;
    return 1 if $line =~ /^\s*(?:error|fatal)\b/i;
    return 1 if $line =~ /\bPermission\s+denied\b/i;
    return 1 if $line =~ /^\s*(?:make|gmake):\s+\*\*\*/i;
    return 1 if $line =~ /\bdoesn'?t satisfy\b/i;
    return 1 if $line =~ /\b(?:failed|failure)\b/i
        && $line =~ /\b(?:build|configure|fetch|install|test|download)\b/i
        && $line !~ /\bSuccessfully\b/i;
    return 1 if $line =~ /\b(?:could not|unable to)\b/i
        && $line =~ /\b(?:resolve|download|fetch|install|configure|build)\b/i;

    return 0;
}



sub normalize_diagnostic {
    my ($lines) = @_;

    my @normalized;

    for my $line (@{$lines}) {
        $line =~ s/\bpin mismatch\b/dependency version mismatch/ig;
        $line =~ s/\bfailed applying pin\b/failed applying dependency version/ig;
        $line =~ s/\bapplying pin\b/applying dependency version/ig;
        $line =~ s/\bpinned version\b/requested dependency version/ig;
        $line =~ s/\bpin\b/dependency version/ig;

        push @normalized, $line;
    }

    return \@normalized;
}

sub diagnostic_pattern {
    my (%args) = @_;

    my $status     = $args{status};
    my $diagnostic = $args{diagnostic};

    return 'UNAVAILABLE'
        if $status eq 'UNAVAILABLE';

    for my $line (@{$diagnostic}) {
        my $text = trim($line);

        next if $text eq '';
        next if $text =~ /^\[inner\]\s+rc=\d+\s*$/;
        next if $text =~ /^\[host\]\b/;

        return 'Dependency version mismatch'
            if $text =~ /\bdependency\s+version\s+mismatch\b/i;

        return 'Dependency version verification failed'
            if $text =~ /\bdependency\s+version\s+verification\s+failed\b/i;

        return "Dependency version install failed: $1"
            if $text =~ /\bfailed\s+applying\s+dependency\s+version\s+(\S+)/i;

        return "CPAN version lookup failed: $1"
            if $text =~ /^\s*!\s+Finding\s+(.+?)\s+on\s+cpanmetadb\s+failed\b/i;

        return "Distribution install failed: $1"
            if $text =~ /^\s*!\s+Installing\s+(.+?)\s+failed\b/i;

        return 'Permission denied'
            if $text =~ /\bPermission\s+denied\b/i;

        return 'Compilation failed'
            if $text =~ /\bcompilation\s+terminated\b/i
            || $text =~ /^\s*(?:make|gmake):\s+\*\*\*/i;

        return 'Dependency requirement not satisfied'
            if $text =~ /\bdoesn'?t satisfy\b/i;
    }

    for my $line (@{$diagnostic}) {
        my $pattern = trim($line);

        next if $pattern eq '';
        next if $pattern =~ /^\[inner\]\s+rc=\d+\s*$/;
        next if $pattern =~ /^\[host\]\b/;
        next if $pattern =~ /^\d{4}-\d{2}-\d{2}\b/;
        next if $pattern =~ /^Successfully\b/i;
        next if $pattern =~ /^Installing\s+\//i;
        next if $pattern =~ /^\d+\s+distributions?\s+installed\b/i;
        next if $pattern =~ /^-->\s+Working\s+on\b/i;
        next if $pattern =~ /^Saving\s+to:/i;
        next if $pattern =~ /^\s*\d+K\b/;

        $pattern =~ s/^\[inner\]\s*//;
        $pattern =~ s{\Q$ENV{HOME}\E}{~}g
            if defined $ENV{HOME} && length $ENV{HOME};

        return $pattern;
    }

    return "$status: no diagnostic text";
}


sub trim {
    my ($value) = @_;

    $value =~ s/^\s+//;
    $value =~ s/\s+$//;

    return $value;
}


sub usage {
    return <<"USAGE";
Usage:
  nonpass_cpanm_logs.pl BATCH_DIRECTORY

Example:
  nonpass_cpanm_logs.pl \\
    /home/ray/Smoker/development/test_results/1000_tests_20260721_190918

To write the standard batch report:
  nonpass_cpanm_logs.pl BATCH_DIRECTORY > BATCH_DIRECTORY/batch_review.txt
USAGE
}