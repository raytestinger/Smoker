use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 't/lib';
use Smoker::TestBatch qw(make_batch read_text);

sub validate_fixture {
    my (%fixture) = @_;
    my $root = tempdir(CLEANUP => 1);
    my ($batch) = make_batch($root, %fixture);
    my $report = File::Spec->catfile($root, 'validation.txt');
    my $raw = system($^X, 'bin/validate_smoker_batch.pl', $batch, $report);
    return ($raw >> 8, read_text($report));
}

my @matrix = (
    [ 0, 'raw rc=8',   { rc=>8,   status=>'FAIL', subtype=>'', evidence=>"ordinary failure\n" } ],
    [ 0, 'raw rc=112', { rc=>112, status=>'FAIL', subtype=>'', evidence=>"ordinary failure\n" } ],
    [ 0, 'timeout subtype', { rc=>8, status=>'FAIL', subtype=>'timeout', note=>'Execution timed out', evidence=>"[host] timeout after 60s\n" } ],
    [ 0, 'log-limit subtype', { rc=>112, status=>'FAIL', subtype=>'log_limit_exceeded', note=>'build log safety limit', evidence_file=>'loglimit.note' } ],
    [ 0, 'framework subtype', { rc=>125, status=>'FAIL', subtype=>'framework_error', note=>'worker exception', evidence_file=>'framework_error.evidence', evidence_file_text=>"reason=worker exception\nstage=reap\n" } ],
    [ 1, 'rc=125 without framework subtype', { rc=>125, status=>'FAIL', subtype=>'', evidence=>"ordinary failure\n" } ],
    [ 1, 'rc=125 framework subtype without evidence', { rc=>125, status=>'FAIL', subtype=>'framework_error', evidence=>"ordinary failure\n" } ],
    [ 1, 'timeout subtype with rc=112', { rc=>112, status=>'FAIL', subtype=>'timeout', note=>'Execution timed out', evidence=>"[host] timeout after 60s\n" } ],
    [ 1, 'log-limit subtype with rc=8', { rc=>8, status=>'FAIL', subtype=>'log_limit_exceeded', note=>'build log safety limit', evidence_file=>'loglimit.note' } ],
    [ 1, 'framework subtype with rc=8', { rc=>8, status=>'FAIL', subtype=>'framework_error', evidence_file=>'framework_error.evidence' } ],
    [ 1, 'unknown subtype', { rc=>2, status=>'FAIL', subtype=>'mystery', evidence=>"ordinary failure\n" } ],
    [ 1, 'timeout missing evidence', { rc=>8, status=>'FAIL', subtype=>'timeout', note=>'Execution timed out', evidence=>"terminated by SIGTERM\n" } ],
    [ 1, 'timeout with SIGKILL note', { rc=>8, status=>'FAIL', subtype=>'timeout', note=>'Execution timed out', evidence=>"killed by SIGKILL\n", evidence_file=>'timeout.note', evidence_file_text=>"SIGKILL signal\n" } ],
    [ 1, 'log limit missing evidence', { rc=>112, status=>'FAIL', subtype=>'log_limit_exceeded', note=>'build log safety limit', evidence=>"ordinary failure\n" } ],
);

for my $case (@matrix) {
    my ($rc, $report) = validate_fixture(%{ $case->[2] });
    is($rc, $case->[0], "validator " . ($case->[0] ? 'rejects ' : 'accepts ') . $case->[1]);
    like($report, $case->[0] ? qr/Assessment: FAIL/ : qr/Assessment: PASS/, "validator reports $case->[1]");
}

done_testing;
