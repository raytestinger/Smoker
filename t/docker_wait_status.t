use strict;
use warnings;

use Test::More;

use lib 'lib';
use Smoker::Docker ();
use Smoker::Result qw(decode_wait_status);

my $pid = fork();
die "fork: $!" unless defined $pid;

if ($pid == 0) {
    setpgrp(0, 0);
    local $SIG{TERM} = 'DEFAULT';
    select undef, undef, undef, 30;
    exit 0;
}

select undef, undef, undef, 0.1;
my $raw = Smoker::Docker::_terminate_process_group($pid);
my $decoded = decode_wait_status($raw);

is($decoded->{signal}, 15,
    'process-group termination returns the reaped child SIGTERM wait status');
is($decoded->{exit_code}, 0,
    'signal termination does not invent a child exit code');

done_testing;
