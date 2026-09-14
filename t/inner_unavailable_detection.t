use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Smoker::Inner ();

my $dir = tempdir(CLEANUP => 1);
my $log = File::Spec->catfile($dir, 'build.log');

sub detected {
    my ($text) = @_;
    open my $fh, '>', $log or die "cannot write $log: $!";
    print {$fh} $text;
    close $fh or die "cannot close $log: $!";
    return Smoker::Inner::_release_unavailable_seen($log, 0);
}

sub local_distribution_fetch_failed {
    my ($text) = @_;
    open my $fh, '>', $log or die "cannot write $log: $!";
    print {$fh} $text;
    close $fh or die "cannot close $log: $!";
    return Smoker::Inner::_local_mirror_distribution_fetch_failed($log, 0);
}

ok(
    detected("Found Example::Module  which doesn't satisfy == 1.23.\n"),
    'detects cpanm exact-version mismatch when the offered version is blank',
);

ok(
    detected("Found Example::Module 2.00 which doesn't satisfy == 1.23.\n"),
    'detects cpanm exact-version mismatch when an offered version is present',
);

ok(
    !detected("Successfully installed Example-Module-1.23\n"),
    'does not label an ordinary successful installation unavailable',
);

ok(
    local_distribution_fetch_failed(
        "! Failed to download file:///mirror/authors/id/E/EX/EXAMPLE/Example-1.23.tar.gz\n"
    ),
    'detects an absent distribution archive referenced by a local CPAN mirror',
);

ok(
    local_distribution_fetch_failed(
        "Fetching file:///mirror/authors/id/E/EX/EXAMPLE/Example-1.23.tar.gz ... FAIL\n"
    ),
    'detects cpanm local-distribution fetch failure form',
);

ok(
    !local_distribution_fetch_failed(
        "Download failed for https://example.invalid/native-library.tar.gz\n"
    ),
    'does not treat a distribution-owned external download as a mirror miss',
);

done_testing;
