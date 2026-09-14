use strict;
use warnings;

use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Smoker::Inner ();

my $ctx = { trace => sub {} };

for my $case (
    [ 'v1.0.10', '1.0.10' ],
    [ '1.000',    '1'      ],
    [ '3.300',    '3.3'    ],
    [ 'v0.0.8',   '0.0.8'  ],
) {
    ok(
        Smoker::Inner::_versions_match($ctx, @{$case}),
        "$case->[0] and $case->[1] are equivalent Perl versions",
    );
}

ok(
    !Smoker::Inner::_versions_match($ctx, '2.22', '2.21'),
    'different versions remain a mismatch',
);

my $lib = tempdir(CLEANUP => 1);
my $probe_dir = File::Spec->catdir($lib, 'Probe');
make_path($probe_dir);

sub write_module {
    my ($name, $body) = @_;
    my $path = File::Spec->catfile($probe_dir, "$name.pm");
    open my $fh, '>', $path or die "cannot write $path: $!";
    print {$fh} $body;
    close $fh or die "cannot close $path: $!";
}

write_module('Noisy', <<'MODULE');
package Probe::Noisy;
our $VERSION = '1.23';
print "ok 1 - load-time TAP\n";
END {
    print "not ok 2 - END-time TAP\n";
    $? = 254;
}
1;
MODULE

write_module('Unversioned', <<'MODULE');
package Probe::Unversioned;
1;
MODULE

write_module('Old', <<'MODULE');
package Probe::Old;
our $VERSION = '2.21';
1;
MODULE

{
    local $ENV{PERL5LIB} = join(':', $lib, grep { defined && length } $ENV{PERL5LIB});
    my @log;
    my $verify_ctx = {
        trace => sub {},
        log   => sub { push @log, @_ },
    };

    is_deeply(
        [ Smoker::Inner::_show_installed_version('Probe::Noisy') ],
        [ 0, '1.23' ],
        'load- and END-time TAP and exit status are excluded from the version probe result',
    );

    is_deeply(
        [ Smoker::Inner::_show_installed_version('Probe::Unversioned') ],
        [ 0, 'undef' ],
        'a module without package VERSION is reported as unverifiable',
    );

    ok(
        Smoker::Inner::_verify_dependency_version($verify_ctx, 'Probe::Noisy', '1.230'),
        'verification accepts a semantically equivalent reported version',
    );

    ok(
        Smoker::Inner::_verify_dependency_version($verify_ctx, 'Probe::Unversioned', '4.56'),
        'verification treats an absent package VERSION as inconclusive',
    );
    like(
        join("\n", @log),
        qr/has no package version; exact-release installation cannot be verified locally/,
        'inconclusive verification is explicitly logged',
    );

    ok(
        !Smoker::Inner::_verify_dependency_version($verify_ctx, 'Probe::Old', '2.22'),
        'verification rejects a genuine installed-version mismatch',
    );
    like(
        join("\n", @log),
        qr/dependency version mismatch for Probe::Old: wanted 2\.22 got 2\.21/,
        'genuine mismatch retains the diagnostic',
    );
}

done_testing;
