use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;
use Text::CSV;

use lib 'lib';
use Smoker::Runner ();

{
    package TestRunner;
    use parent 'Smoker::Runner';

    sub set_attempts { $_[0]{test_attempts} = $_[1] }

    sub _run_docker_attempt {
        my ($self, %args) = @_;
        my $attempt = shift @{ $self->{test_attempts} };
        die 'missing fake attempt' unless $attempt;

        open my $cmd, '>', $args{cmd_file} or die $!;
        print {$cmd} "fake docker command\n";
        close $cmd or die $!;
        open my $out, '>', $args{run_out} or die $!;
        print {$out} ($attempt->{out} // "fake execution\n");
        close $out or die $!;

        for my $pair (
            [ unavailable => 'unavailable.note' ],
            [ log_limit   => 'loglimit.note' ],
        ) {
            next unless defined $attempt->{ $pair->[0] };
            open my $fh, '>', File::Spec->catfile($args{run_dir}, $pair->[1]) or die $!;
            print {$fh} $attempt->{ $pair->[0] };
            close $fh or die $!;
        }

        return { %$attempt };
    }
}

sub run_case {
    my ($name, $attempts, %opts) = @_;
    my $dir = tempdir(CLEANUP => 1);
    my $runner = TestRunner->new(
        smoker_root => '.', batch => $name, outdir => $dir,
    );
    $runner->set_attempts([ map { +{%$_} } @$attempts ]);

    local $ENV{SMOKER_LOCAL_MIRROR};
    $ENV{SMOKER_LOCAL_MIRROR} = $dir if $opts{mirror};
    my $returned = $runner->run_one(
        run_id => 1, module => 'Example::Module', version => '1.0',
    );

    my $csv = Text::CSV->new({ binary => 1, auto_diag => 1 });
    open my $fh, '<', File::Spec->catfile($dir, 'summary.csv') or die $!;
    my $header = $csv->getline($fh);
    $csv->column_names(@$header);
    my $row = $csv->getline_hr($fh);
    close $fh;

    my %meta;
    open my $mfh, '<', File::Spec->catfile($row->{run_dir}, 'result.meta') or die $!;
    while (<$mfh>) { chomp; my ($k, $v) = split /=/, $_, 2; $meta{$k} = $v; }
    close $mfh;
    return ($returned, $row, \%meta);
}

for my $case (
    [ raw_124 => [{ rc => 124 }], 124 ],
    [ raw_137 => [{ rc => 137 }], 137 ],
    [ raw_143 => [{ rc => 143 }], 143 ],
    [ raw_4   => [{ rc => 4 }],     4 ],
) {
    my ($returned, $row, $meta) = run_case($case->[0], $case->[1]);
    is($returned, $case->[2], "$case->[0] preserves rc");
    is($row->{status}, 'FAIL', "$case->[0] is FAIL");
    is($meta->{subtype}, '', "$case->[0] has no invented subtype");
}

{
    my ($returned, $row, $meta) = run_case(timeout => [{ rc => 124, timed_out => 1 }]);
    is($returned, 8, 'explicit Docker timeout normalizes to rc=8');
    is($row->{status}, 'FAIL', 'explicit timeout is FAIL');
    is($meta->{subtype}, 'timeout', 'explicit timeout records subtype');
    like($row->{note}, qr/timed out/i, 'explicit timeout records note');
}

{
    my ($returned, $row, $meta) = run_case(framework => [{
        rc => 137, framework_error => 1, raw_wait_status => 2304, interrupted => 1,
        interrupt_signal => 'KILL',
    }]);
    is($returned, 125, 'framework result retains reserved rc=125');
    is($meta->{subtype}, 'framework_error', 'Runner writes framework_error subtype');
    is($meta->{raw_wait_status}, 2304, 'Runner retains raw wait status');
    is($meta->{raw_return_code}, 137, 'Runner retains return code before framework normalization');
    is($meta->{interrupt_signal}, 'KILL', 'Runner retains original signal');
    ok(-s File::Spec->catfile($row->{run_dir}, 'framework_error.evidence'),
        'Runner writes explicit framework-error evidence');
}

{
    my ($returned, $row, $meta) = run_case(log_limit => [{
        rc => 112,
        log_limit_exceeded => 1,
        log_limit => "build.log exceeded safety limit\n",
    }]);
    is($returned, 112, 'explicit log limit preserves rc=112');
    is($meta->{subtype}, 'log_limit_exceeded', 'explicit log limit records subtype');
    like($row->{note}, qr/aborted.*log/i, 'explicit log limit records note');
}

{
    my ($returned, $row, $meta) = run_case(
        retry_without_evidence => [{ rc => 4 }, { rc => 4 }], mirror => 1,
    );
    is($returned, 4, 'live retry rc=4 without causal evidence remains rc=4');
    is($row->{status}, 'FAIL', 'unconfirmed live retry is FAIL');
}

{
    my ($returned, $row, $meta) = run_case(
        retry_with_evidence => [
            { rc => 4 },
            { rc => 4, unavailable => "requested archive unavailable on live CPAN\n" },
        ],
        mirror => 1,
    );
    is($returned, 111, 'live retry rc=4 with nonempty causal evidence normalizes to rc=111');
    is($row->{status}, 'UNAVAILABLE', 'confirmed live retry is UNAVAILABLE');
}

done_testing;
