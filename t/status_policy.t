use strict;
use warnings;

use Test::More;

use lib 'lib';
use Smoker::Result qw(classify_result);

my @cases = (
    [ 'pass',                 { rc => 0 },                            0,   'PASS',        '',                   qr/\A\z/ ],
    [ 'unconfirmed rc=4',     { rc => 4 },                            4,   'FAIL',        '',                   qr/\A\z/ ],
    [ 'confirmed rc=4',       { rc => 4, confirmed_unavailable => 1 }, 111, 'UNAVAILABLE', '',                  qr/\A\z/ ],
    [ 'unavailable rc=111',   { rc => 111 },                          111, 'UNAVAILABLE', '',                   qr/\A\z/ ],
    [ 'raw timeout rc=8',     { rc => 8 },                            8,   'FAIL',        '',                   qr/\A\z/ ],
    [ 'confirmed timeout',    { rc => 124, timed_out => 1 },          8,   'FAIL',        'timeout',            qr/timed out/i ],
    [ 'raw Docker rc=124',    { rc => 124 },                          124, 'FAIL',        '',                   qr/\A\z/ ],
    [ 'raw SIGKILL rc=137',   { rc => 137 },                          137, 'FAIL',        '',                   qr/\A\z/ ],
    [ 'raw SIGTERM rc=143',   { rc => 143 },                          143, 'FAIL',        '',                   qr/\A\z/ ],
    [ 'raw abort rc=112',     { rc => 112 },                          112, 'FAIL',        '',                   qr/\A\z/ ],
    [ 'confirmed log limit',  { rc => 112, log_limit_exceeded => 1 }, 112, 'FAIL',        'log_limit_exceeded', qr/aborted.*log/i ],
    [ 'ordinary failure',     { rc => 2 },                            2,   'FAIL',        '',                   qr/\A\z/ ],
    [ 'reserved framework rc=125', { rc => 125 },                     125, 'FAIL',        'framework_error',    qr/\A\z/ ],
    [ 'framework state',      { rc => 125, framework_error => 1 },    125, 'FAIL',        'framework_error',    qr/\A\z/ ],
);

for my $case (@cases) {
    my ($name, $args, $expected_rc, $expected_status, $expected_subtype, $note_re) = @$case;
    my $result = classify_result(%$args);

    is($result->{rc}, $expected_rc, "$name: normalized rc");
    is($result->{status}, $expected_status, "$name: status");
    is($result->{subtype}, $expected_subtype, "$name: subtype");
    like($result->{note}, $note_re, "$name: note");
}

my $undefined = classify_result(rc => undef);
is($undefined->{rc}, 125, 'undefined result becomes reserved framework rc');
is($undefined->{status}, 'FAIL', 'undefined result becomes FAIL');
is($undefined->{subtype}, 'framework_error', 'undefined result uses reserved framework subtype');

done_testing;
