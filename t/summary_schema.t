use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Smoker::Runner ();

my @expected = qw(
    run_id
    batch
    base
    mode
    module
    version
    dep_one
    dep_one_version
    dep_two
    dep_two_version
    status
    rc
    start_ts
    end_ts
    elapsed_s
    run_dir
    note
);

my $outdir = tempdir(CLEANUP => 1);
Smoker::Runner->new(
    smoker_root => '.',
    batch       => 'schema_test',
    outdir      => $outdir,
);

my $summary = File::Spec->catfile($outdir, 'summary.csv');
open my $fh, '<', $summary or die "read $summary: $!";
my $header = <$fh>;
my $extra = <$fh>;
close $fh or die "close $summary: $!";

chomp $header;
is($header, join(',', @expected), 'summary.csv has the exact approved 17-column header');
ok(!defined $extra, 'summary.csv initialization writes exactly one header line');

done_testing;
