use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 't/lib';
use Smoker::TestBatch qw(make_batch read_text);

sub run_tool {
    my ($script, %fixture) = @_;
    my $root = tempdir(CLEANUP => 1);
    my ($batch) = make_batch($root, %fixture);
    my $report = File::Spec->catfile($root, 'report.txt');
    my $raw = system($^X, $script, $batch, $report);
    return ($raw >> 8, read_text($report));
}

my @accepted = (
    [ 'raw rc=8',   { rc=>8,   status=>'FAIL', subtype=>'', evidence=>"ordinary failure\n" } ],
    [ 'raw rc=112', { rc=>112, status=>'FAIL', subtype=>'', evidence=>"ordinary failure\n" } ],
    [ 'timeout subtype', {
        rc=>8, status=>'FAIL', subtype=>'timeout', note=>'Execution timed out',
        evidence=>"[host] timeout after 60s\n",
    } ],
    [ 'log-limit subtype', {
        rc=>112, status=>'FAIL', subtype=>'log_limit_exceeded',
        note=>'Execution aborted because the build log exceeded the safety limit',
        evidence_file=>'loglimit.note', evidence_file_text=>"build log exceeded safety limit\n",
    } ],
    [ 'framework subtype', {
        rc=>125, status=>'FAIL', subtype=>'framework_error',
        evidence_file=>'framework_error.evidence', evidence_file_text=>"worker exception: test failure\n",
    } ],
);

my @rejected = (
    [ 'rc=125 without framework subtype', { rc=>125, status=>'FAIL', subtype=>'', evidence=>"ordinary failure\n" } ],
    [ 'rc=125 framework subtype without evidence', { rc=>125, status=>'FAIL', subtype=>'framework_error', evidence=>"ordinary failure\n" } ],
    [ 'timeout subtype with rc=112', { rc=>112, status=>'FAIL', subtype=>'timeout', note=>'Execution timed out', evidence=>"[host] timeout after 60s\n" } ],
    [ 'log-limit subtype with rc=8', { rc=>8, status=>'FAIL', subtype=>'log_limit_exceeded', note=>'build log safety limit', evidence_file=>'loglimit.note' } ],
    [ 'framework subtype with rc=8', { rc=>8, status=>'FAIL', subtype=>'framework_error', evidence_file=>'framework_error.evidence' } ],
    [ 'unknown subtype',             { rc=>2, status=>'FAIL', subtype=>'mystery', evidence=>"ordinary failure\n" } ],
    [ 'timeout missing evidence',    { rc=>8, status=>'FAIL', subtype=>'timeout', note=>'Execution timed out', evidence=>"terminated by SIGTERM\n" } ],
    [ 'timeout with SIGKILL note',   { rc=>8, status=>'FAIL', subtype=>'timeout', note=>'Execution timed out', evidence=>"killed by SIGKILL\n", evidence_file=>'timeout.note', evidence_file_text=>"SIGKILL signal\n" } ],
    [ 'log limit missing evidence',  { rc=>112, status=>'FAIL', subtype=>'log_limit_exceeded', note=>'build log safety limit', evidence=>"ordinary failure\n" } ],
);

for my $script ('bin/audit_result_classification.pl', 'tools/analyze_results.pl') {
    for my $case (@accepted) {
        my ($rc, $report) = run_tool($script, %{ $case->[1] });
        is($rc, 0, "$script accepts $case->[0]");
        like($report, qr/Classification evidence: PASS\b/, "$script supports $case->[0]");
    }
    for my $case (@rejected) {
        my ($rc, $report) = run_tool($script, %{ $case->[1] });
        is($rc, 1, "$script rejects $case->[0]");
        like($report, qr/UNSUPPORTED|Classification evidence: FAIL/, "$script reports $case->[0]");
    }
}

done_testing;
