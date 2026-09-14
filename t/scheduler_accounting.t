use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;
use lib 'lib';
use Smoker::Scheduler ();
use Smoker::Result qw(finalize_result);

sub complete_child_result {
    my (%args) = @_;

    my $run_dir = $args{run_dir};
    my $suite   = $args{suite};
    my $rc      = $args{rc};
    my $status  = $rc == 0 ? 'PASS' : $rc == 111 ? 'UNAVAILABLE' : 'FAIL';

    open my $cmd, '>', File::Spec->catfile($run_dir, '00_command.txt')
        or die "write command: $!";
    print {$cmd} "accounting fixture command\n";
    close $cmd or die "close command: $!";

    finalize_result(
        run_id          => '000001',
        batch           => 'suite',
        base            => 'perl:5.38',
        mode            => 'baseline',
        module          => 'Example::Module',
        version         => '1.0',
        dep_one         => '',
        dep_one_version => '',
        dep_two         => '',
        dep_two_version => '',
        status          => $status,
        subtype         => '',
        rc              => $rc,
        start_ts        => '2026-01-01T00:00:00Z',
        end_ts          => '2026-01-01T00:00:01Z',
        elapsed_s       => '1.000000',
        run_dir         => $run_dir,
        summary_file    => File::Spec->catfile($suite, 'summary.csv'),
        note            => '',
        raw_return_code => $rc,
        raw_wait_status => '',
        interrupted     => 0,
        interrupt_signal => '',
    );
}

sub account_exit {
    my ($worker_rc, $signal, $artifact_rc) = @_;
    $artifact_rc = $worker_rc unless defined $artifact_rc;

    my $root = tempdir(CLEANUP => 1);
    my $suite = File::Spec->catdir($root, 'suite');
    mkdir $suite or die "mkdir $suite: $!";

    my $run_dir = Smoker::Scheduler::reserve_run_dir(
        suite_root => $suite,
        run_id     => 1,
    );

    my $pid = fork();
    die "fork: $!" unless defined $pid;
    if (!$pid) {
        complete_child_result(
            suite   => $suite,
            run_dir => $run_dir,
            rc      => $artifact_rc,
        ) unless $signal;

        if ($signal) { kill $signal, $$; select undef, undef, undef, 1; }
        exit $worker_rc;
    }
    my %children = ($pid => {
        seq       => 1,
        module    => 'Example::Module',
        version   => '1.0',
        mode      => 'baseline',
        base      => 'perl:5.38',
        run_dir   => $run_dir,
        suite_root => $suite,
        batch     => 'suite',
        row       => {
            base            => 'perl:5.38',
            mode            => 'baseline',
            module          => 'Example::Module',
            version         => '1.0',
            dep_one         => '',
            dep_one_version => '',
            dep_two         => '',
            dep_two_version => '',
        },
        dispatched_at => time(),
    });
    my %totals = (pass => 0, fail => 0, unavailable => 0, other => 0);
    Smoker::Scheduler::reap_one(\%children, \%totals);
    return \%totals;
}

is_deeply(account_exit(0),   {pass=>1, fail=>0, unavailable=>0, other=>0}, 'rc=0 accounted PASS');
is_deeply(account_exit(111), {pass=>0, fail=>0, unavailable=>1, other=>0}, 'rc=111 accounted UNAVAILABLE');
is_deeply(account_exit(4, undef, 2), {pass=>0, fail=>1, unavailable=>0, other=>0}, 'worker exit rc=4 with finalized module FAIL is accounted FAIL');
for my $rc (8, 112, 124, 137, 143) {
    is_deeply(account_exit($rc), {pass=>0, fail=>1, unavailable=>0, other=>0}, "rc=$rc accounted FAIL");
}
for my $signal ('TERM', 'KILL') {
    is_deeply(account_exit(0, $signal), {pass=>0, fail=>1, unavailable=>0, other=>0}, "$signal worker termination accounted framework FAIL");
}

done_testing;
