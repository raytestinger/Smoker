#!/usr/bin/env perl
use strict;
use warnings;

use Getopt::Long qw(GetOptions);
use Cwd qw(abs_path);
use File::Spec;

BEGIN {
    require FindBin;
    FindBin->import(qw($Bin));
    require Cwd;
    require File::Spec;

    my $smoker_home =
           $ENV{SMOKER_HOME}
        || $ENV{SMOKER_ROOT}
        || Cwd::abs_path(File::Spec->catdir($FindBin::Bin, '..'));

    die "ERROR: cannot resolve SMOKER_HOME from $FindBin::Bin/..\n"
        unless $smoker_home;

    $ENV{SMOKER_HOME} = $smoker_home;
    $ENV{SMOKER_ROOT} = $smoker_home;

    unshift @INC, File::Spec->catdir($smoker_home, 'lib');

    require Log::Log4perl;

    if (!Log::Log4perl->initialized()) {
        Log::Log4perl->easy_init({
            level  => 'INFO',
            layout => '%m%n',
        });
    }
}

use Smoker::Scheduler;

sub die_msg {
    my ($msg) = @_;
    print STDERR "ERROR: $msg\n";
    exit 2;
}

my ($smoker_home, $smoker_root, $plan_csv, $suite_root, $jobs, $timeout);

GetOptions(
    'smoker-home=s' => \$smoker_home,
    'smoker-root=s' => \$smoker_root,
    'plan=s'        => \$plan_csv,
    'suite-root=s'  => \$suite_root,
    'jobs=i'        => \$jobs,
    'timeout=i'     => \$timeout,
) or die_msg(usage());

$smoker_home ||= $smoker_root || $ENV{SMOKER_HOME} || $ENV{SMOKER_ROOT};
$smoker_root ||= $smoker_home;

$smoker_home = abs_path($smoker_home)
    or die_msg("cannot resolve smoker home/root");

$ENV{SMOKER_HOME} = $smoker_home;
$ENV{SMOKER_ROOT} = $smoker_home;

$jobs ||= $ENV{SMOKER_JOBS} || 8;
$ENV{SMOKER_JOBS} = $jobs;

die_msg("missing --plan")       unless $plan_csv;
die_msg("missing --suite-root") unless $suite_root;

my %args = (
    smoker_root => $smoker_home,
    plan        => $plan_csv,
    suite_root  => $suite_root,
    jobs        => $jobs,
    timeout     => ($timeout || $ENV{SMOKER_RUN_TIMEOUT} || 1800),
);

Smoker::Scheduler::run_plan_csv(%args);

sub usage {
    return <<'USAGE';
usage:
  perl bin/run_plan_csv.pl --smoker-root /path/to/Smoker --plan config/plans/sample.csv --suite-root test_results/sample --jobs 8
USAGE
}
