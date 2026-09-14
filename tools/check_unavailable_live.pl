#!/usr/bin/env perl
use strict;
use warnings;
use Getopt::Long qw(GetOptions);
use File::Find qw(find);
use File::Spec;
use IPC::Open3 qw(open3);
use Symbol qw(gensym);

my ($input, $root);
my $output = 'unavailable_live_check.csv';
my $mirror = 'https://cpan.metacpan.org';
my $help;

GetOptions(
    'input=s'  => \$input,
    'root=s'   => \$root,      # retained for compatibility
    'output=s' => \$output,
    'mirror=s' => \$mirror,
    'help'     => \$help,
) or die usage();

$input //= $root;
$input //= shift @ARGV;
die usage() if $help || !defined($input) || $input eq '' || @ARGV;

die "cpanm was not found in PATH\n" unless command_exists('cpanm');
die "curl was not found in PATH\n" unless command_exists('curl');

my %specs;
if (-f $input) {
    read_input_file($input, \%specs);
} elsif (-d $input) {
    my @logs;
    find(
        sub {
            return unless -f $_;
            return unless $_ eq 'run_smoker.log' || $_ eq 'trace.log';
            push @logs, $File::Find::name;
        },
        $input,
    );
    die "No run_smoker.log or trace.log found under $input\n" unless @logs;
    read_input_file($_, \%specs) for @logs;
} else {
    die "No such file or directory: $input\n";
}

die "No module\@version records found in $input\n" unless %specs;

open my $out, '>', $output or die "Cannot write $output: $!\n";
print {$out} csv(qw(spec occurrences cpanm_rc url http_code result detail)), "\n";

my ($found, $missing, $errors) = (0, 0, 0);
for my $spec (sort keys %specs) {
    # Do not use --mirror-only here. Exact historical releases such as
    # Try::Tiny@0.31 may require cpanm's MetaCPAN/BackPAN resolution.
    # Also suppress the caller's PERL_CPANM_OPT so a configured local
    # MiniCPAN mirror cannot override this independent live-CPAN check.
    my ($rc, $stdout, $stderr);
    {
        local $ENV{PERL_CPANM_OPT} = '';
        ($rc, $stdout, $stderr) = run_command(
            'cpanm', '--info', '--mirror', $mirror, $spec
        );
    }

    $stdout =~ s/^\s+|\s+$//g;
    $stderr =~ s/^\s+|\s+$//g;
    # cpanm --info normally prints either:
    #   https://.../authors/id/E/ET/ETHER/Try-Tiny-0.31.tar.gz
    # or the shorthand:
    #   ETHER/Try-Tiny-0.31.tar.gz
    # Some versions may print the full CPAN-relative A/AU/AUTHOR path.
    my ($url) = $stdout =~ m{(https?://\S+)};

    if (!$url && $stdout =~ m{^([^\s]+\.(?:tar\.gz|tgz|zip))$}i) {
        my $path = $1;
        $path =~ s{^/+}{};

        my @parts = split m{/}, $path;
        if (@parts == 2) {
            my ($author, $file) = @parts;
            my $first = substr($author, 0, 1);
            my $first_two = substr($author, 0, 2);
            $path = join '/', $first, $first_two, $author, $file;
        }

        $url = $mirror;
        $url =~ s{/+$}{};
        $url .= '/authors/id/' . $path;
    }
    my ($http_code, $result, $detail);

    if ($rc == 0 && $url) {
        ($http_code) = capture_command(
            'curl', '-L', '-sS', '-o', '/dev/null', '-w', '%{http_code}', $url
        );
        $http_code =~ s/\s+//g;
        if ($http_code =~ /^(?:200|206)$/) {
            $result = 'EXACT_FOUND';
            $detail = 'cpanm resolved the version-qualified request and URL fetched';
            $found++;
        } else {
            $result = 'FETCH_ERROR';
            $detail = "cpanm resolved release but curl returned HTTP $http_code";
            $errors++;
        }
    } elsif ($rc != 0) {
        $http_code = '';
        $result = 'NOT_RESOLVED';
        $detail = $stderr || $stdout || 'cpanm returned no explanation';
        $missing++;
    } else {
        $http_code = '';
        $result = 'ERROR';
        $detail = 'cpanm exited successfully but returned no recognized distribution path; stdout=' . $stdout . '; stderr=' . $stderr;
        $errors++;
    }

    print {$out} csv(
        $spec, $specs{$spec}, $rc, ($url // ''), ($http_code // ''),
        $result, $detail,
    ), "\n";
    printf "%-42s %-12s %s\n", $spec, $result, ($url // '');
}
close $out;

print "\nUnique releases checked: ", scalar(keys %specs), "\n";
print "EXACT_FOUND: $found  NOT_RESOLVED: $missing  ERRORS: $errors\n";
print "Report: $output\n";

sub read_input_file {
    my ($file, $specs) = @_;
    open my $fh, '<', $file or die "Cannot read $file: $!\n";
    while (my $line = <$fh>) {
        chomp $line;

        # Flat list format: "190 Test::More@1.302190"
        if ($line =~ /^\s*(\d+)\s+([^\s]+\@[^\s]+)\s*$/) {
            $specs->{$2} += $1;
            next;
        }

        # Smoker log format: "unavailable release: Test::More@1.302190"
        if ($line =~ /unavailable release:\s*([^\s]+\@[^\s]+)/) {
            $specs->{$1}++;
            next;
        }

        # Also accept a bare module@version line.
        if ($line =~ /^\s*([^\s]+\@[^\s]+)\s*$/) {
            $specs->{$1}++;
        }
    }
    close $fh;
}

sub command_exists {
    my ($name) = @_;
    for my $dir (File::Spec->path) {
        return 1 if -x File::Spec->catfile($dir, $name);
    }
    return 0;
}

sub run_command {
    my @cmd = @_;
    my $err = gensym;
    my ($in, $out);
    my $pid = open3($in, $out, $err, @cmd);
    close $in;
    local $/;
    my $stdout = <$out> // '';
    my $stderr = <$err> // '';
    waitpid($pid, 0);
    return ($? >> 8, $stdout, $stderr);
}

sub capture_command {
    my @cmd = @_;
    my ($rc, $stdout, $stderr) = run_command(@cmd);
    return ($stdout, $rc, $stderr);
}

sub csv {
    return join ',', map {
        my $v = defined($_) ? $_ : '';
        $v =~ s/"/""/g;
        qq{"$v"};
    } @_;
}

sub usage {
    return <<'USAGE';
Usage:
  perl check_unavailable_live.pl unavailable
  perl check_unavailable_live.pl --input unavailable [options]
  perl check_unavailable_live.pl --root RUN_DIRECTORY [options]

Options:
  --output FILE   CSV report name (default: unavailable_live_check.csv)
  --mirror URL    Live CPAN mirror (default: https://cpan.metacpan.org)

Input may be:
  * a flat list containing lines such as "190 Test::More@1.302190"
  * a Smoker run_smoker.log or trace.log
  * a completed Smoker run directory

The script does not run Smoker and does not install anything.
It clears PERL_CPANM_OPT and does not use --mirror-only, allowing cpanm
to resolve exact historical releases through its normal live lookup.
USAGE
}
