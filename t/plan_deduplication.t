use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;
use Text::CSV;

use lib 'lib';
use Smoker::PlanCSV qw(canonical_row_key);
use lib 't/lib';
use Smoker::TestBatch qw(make_batch);

my @schema = qw(
    base mode module version
    dep_one dep_one_version dep_two dep_two_version
);

my $root = File::Spec->rel2abs('.');
my $tmp  = tempdir(CLEANUP => 1);

sub csv_row {
    my (@fields) = @_;
    my $csv = Text::CSV->new({ binary => 1, eol => "\n" });
    open my $fh, '>', \my $out or die "open scalar: $!";
    $csv->print($fh, \@fields) or die $csv->error_diag;
    close $fh;
    chomp $out;
    return $out;
}

sub write_file {
    my ($path, $text) = @_;
    open my $fh, '>', $path or die "write $path: $!";
    print {$fh} $text;
    close $fh or die "close $path: $!";
}

sub read_csv_rows {
    my ($path) = @_;
    my $csv = Text::CSV->new({ binary => 1, auto_diag => 1 });
    open my $fh, '<', $path or die "read $path: $!";
    my @rows;
    while (my $row = $csv->getline($fh)) {
        push @rows, [@$row];
    }
    close $fh;
    return \@rows;
}

sub run_plan_dedup {
    my ($name, @rows) = @_;

    my $input = File::Spec->catfile($tmp, "$name.in.csv");
    my $out   = File::Spec->catfile($tmp, "$name.out.csv");
    my $dup   = File::Spec->catfile($tmp, "$name.dup.csv");

    write_file(
        $input,
        join("\n", csv_row(@schema), @rows) . "\n",
    );

    my @cmd = (
        $^X,
        File::Spec->catfile($root, 'tools', 'plan_dedup.pl'),
        '--input', $input,
        '--output', $out,
        '--duplicates-output', $dup,
        '--no-verbose',
    );

    my $output = qx{@cmd 2>&1};
    my $rc = $? >> 8;

    return {
        rc     => $rc,
        output => $output,
        out    => -f $out ? read_csv_rows($out) : [],
        dup    => -f $dup ? read_csv_rows($dup) : [],
    };
}

sub load_run_smoker_dedup {
    return if defined &main::deduplicate_plan;

    local @ARGV = ();
    my $ok = do File::Spec->catfile($root, 'Run_Smoker.pl');
    my $err = $@ || $!;

    ok(!$ok, 'Run_Smoker.pl does not run without a plan during test loading');
    ok(defined &main::deduplicate_plan, 'loaded Run_Smoker.pl deduplicate_plan subroutine');
    note("Run_Smoker.pl load stopped as expected: $err") if $err;
}

sub run_launcher_dedup {
    my ($name, @rows) = @_;

    load_run_smoker_dedup();

    my $input = File::Spec->catfile($tmp, "$name.launcher.in.csv");
    my $out   = File::Spec->catfile($tmp, "$name.launcher.out.csv");
    my $dup   = File::Spec->catfile($tmp, "$name.launcher.dup.csv");

    write_file(
        $input,
        join("\n", csv_row(@schema), @rows) . "\n",
    );

    my @counts = main::deduplicate_plan(
        source_path     => $input,
        output_path     => $out,
        duplicates_path => $dup,
    );

    return {
        counts => \@counts,
        out    => read_csv_rows($out),
        dup    => read_csv_rows($dup),
    };
}

sub read_text {
    my ($path) = @_;
    open my $fh, '<', $path or die "read $path: $!";
    local $/;
    my $text = <$fh>;
    close $fh or die "close $path: $!";
    return $text;
}

sub run_launcher_dedup_text {
    my ($name, $text) = @_;

    load_run_smoker_dedup();

    my $input = File::Spec->catfile($tmp, "$name.launcher.in.csv");
    my $out   = File::Spec->catfile($tmp, "$name.launcher.out.csv");
    my $dup   = File::Spec->catfile($tmp, "$name.launcher.dup.csv");

    write_file($input, $text);

    my @counts = main::deduplicate_plan(
        source_path     => $input,
        output_path     => $out,
        duplicates_path => $dup,
    );

    return {
        counts   => \@counts,
        out_text => read_text($out),
        dup_text => read_text($dup),
        out      => read_csv_rows($out),
        dup      => read_csv_rows($dup),
    };
}

isnt(
    canonical_row_key(["a\x1E", 'b']),
    canonical_row_key(['a', "\x1Eb"]),
    'canonical row identity is collision-free across field boundaries with embedded separator',
);

isnt(
    canonical_row_key(['a', '']),
    canonical_row_key(['a']),
    'canonical row identity distinguishes an empty field from a missing field',
);

isnt(
    canonical_row_key(['ab', 'c']),
    canonical_row_key(['a', 'bc']),
    'canonical row identity distinguishes field-boundary differences',
);

isnt(
    canonical_row_key(["a\x1E\x1F\n", 'b']),
    canonical_row_key(["a\x1E", "\x1F\nb"]),
    'canonical row identity preserves embedded separator and control characters',
);

isnt(
    canonical_row_key(['a', 'b']),
    canonical_row_key(['a', 'b', '']),
    'canonical row identity distinguishes differing field counts',
);

my $ordinary = 'perl:5.38,baseline,DateTime,1.66,,,,';
my $ordinary_dup = run_plan_dedup(
    'ordinary',
    $ordinary,
    $ordinary,
);
is($ordinary_dup->{rc}, 0, 'ordinary duplicate rows: plan_dedup exits cleanly');
is(scalar(@{ $ordinary_dup->{out} }) - 1, 1, 'ordinary duplicate rows: one unique row');
is(scalar(@{ $ordinary_dup->{dup} }) - 1, 1, 'ordinary duplicate rows: one skipped duplicate');

my $quoted_equivalent = run_launcher_dedup(
    'launcher_quoted_equivalent',
    'perl:5.38,baseline,DateTime,1.66,,,,',
    '"perl:5.38",baseline,DateTime,1.66,,,,',
);
is_deeply(
    $quoted_equivalent->{counts},
    [2, 1, 1],
    'Run_Smoker.pl deduplicates equivalent quoted and unquoted rows',
);

my $blank_comment_policy = run_launcher_dedup_text(
    'launcher_blank_comment_policy',
    join(
        '',
        csv_row(@schema) . "\n",
        "\n",
        "   # comment preserved\n",
        "perl:5.38,baseline,Comment::Policy,1.0,,,,\n",
        "  \n",
        "\t# tab-indented comment preserved\n",
        '"perl:5.38",baseline,Comment::Policy,1.0,,,,' . "\n",
    ),
);
my $schema_header = csv_row(@schema);
is_deeply(
    $blank_comment_policy->{counts},
    [2, 1, 1],
    'Run_Smoker.pl ignores blank/comment lines for plan-row counts',
);
like(
    $blank_comment_policy->{out_text},
    qr/\A\Q$schema_header\E\n\n   \# comment preserved\n/,
    'Run_Smoker.pl preserves leading blank and comment lines in deduplicated output',
);
like(
    $blank_comment_policy->{out_text},
    qr/\n  \n\t\# tab-indented comment preserved\n/,
    'Run_Smoker.pl preserves later blank and comment lines in deduplicated output',
);
unlike(
    $blank_comment_policy->{dup_text},
    qr/comment preserved/,
    'Run_Smoker.pl does not write comment lines to skipped duplicates',
);
is(scalar(@{ $blank_comment_policy->{dup} }) - 1, 1,
    'Run_Smoker.pl writes only duplicate plan rows to skipped duplicates');
is(
    $blank_comment_policy->{dup_text},
    $schema_header . "\n" . csv_row('perl:5.38', 'baseline', 'Comment::Policy', '1.0', '', '', '', '') . "\n",
    'Run_Smoker.pl does not write blank lines to skipped duplicates',
);

{
    my $input = File::Spec->catfile($tmp, 'vary-two-tools.csv');
    my $analysis = File::Spec->catfile($tmp, 'vary-two-tools.analysis.txt');
    my $balanced = File::Spec->catfile($tmp, 'vary-two-tools.balanced.csv');
    write_file(
        $input,
        csv_row(@schema) . "\n"
            . csv_row('perl:5.38', 'vary-two', 'Pair::Tools', '1.0', 'Dep::A', '1', 'Dep::B', '2') . "\n"
            . csv_row('perl:5.38', 'vary-two', 'Pair::Tools', '1.0', 'Dep::B', '2', 'Dep::A', '1') . "\n",
    );

    my $analyze_raw = system(
        $^X, File::Spec->catfile($root, 'tools', 'plan_analyze.pl'),
        '--input', $input, '--output', $analysis,
    );
    is($analyze_raw >> 8, 0, 'plan_analyze accepts reversed vary-two tuples');
    like(read_text($analysis), qr/^Unique rows:\s+1$/m,
        'plan_analyze counts reversed vary-two tuples as one logical test');
    like(read_text($analysis), qr/^Duplicate rows:\s+1$/m,
        'plan_analyze reports the reversed vary-two row as duplicate');

    my $balance_output = qx{$^X tools/plan_balance.pl --input "$input" --output "$balanced" 2>&1};
    my $balance_rc = $? >> 8;
    isnt($balance_rc, 0,
        'plan_balance rejects reversed vary-two tuples as duplicate input');
    like($balance_output, qr/duplicate execution row/i,
        'plan_balance duplicate rejection identifies the logical collision');
}

{
    my $fixture_root = tempdir(CLEANUP => 1);
    my ($batch) = make_batch($fixture_root, rc => 0, status => 'PASS');
    my $header = csv_row(@schema) . "\n";
    my $left = csv_row('perl:5.38', 'vary-two', 'Example::Module', '1.0', 'Dep::A', '1', 'Dep::B', '2') . "\n";
    my $right = csv_row('perl:5.38', 'vary-two', 'Example::Module', '1.0', 'Dep::B', '2', 'Dep::A', '1') . "\n";
    write_file(File::Spec->catfile($batch, 'original_plan.csv'), $header . $left . $right);
    write_file(File::Spec->catfile($batch, 'plan_deduplicated.csv'), $header . $left);
    write_file(File::Spec->catfile($batch, 'skipped_dup.csv'), $header . $right);
    my $report = File::Spec->catfile($fixture_root, 'validation.txt');
    my $raw = system($^X, 'bin/validate_smoker_batch.pl', $batch, $report);
    is($raw >> 8, 0,
        'validator recomputation accepts reversed vary-two duplicate accounting');
    like(read_text($report), qr/Recomputed removed duplicate rows:\s+1/,
        'validator independently recomputes the reversed vary-two duplicate');
}

my $comma_dup = run_plan_dedup(
    'embedded_comma',
    'perl:5.38,baseline,"Comma,Test",1.0,,,,',
    '"perl:5.38",baseline,"Comma,Test",1.0,,,,',
);
is($comma_dup->{rc}, 0, 'embedded comma: plan_dedup exits cleanly');
is(scalar(@{ $comma_dup->{out} }) - 1, 1, 'embedded comma: equivalent rows deduplicate');
is($comma_dup->{out}[1][2], 'Comma,Test', 'embedded comma: parsed field is preserved');

my $escaped_quote_distinct = run_plan_dedup(
    'escaped_quote_distinct',
    'perl:5.38,baseline,"Quote""Test",1.0,,,,',
    'perl:5.38,baseline,QuoteTest,1.0,,,,',
);
is($escaped_quote_distinct->{rc}, 0, 'escaped double quote: plan_dedup exits cleanly');
is(scalar(@{ $escaped_quote_distinct->{out} }) - 1, 2,
    'escaped double quote: distinct parsed values remain distinct');
is($escaped_quote_distinct->{out}[1][2], 'Quote"Test',
    'escaped double quote: parsed quote is preserved');

my $empty_field_dup = run_plan_dedup(
    'empty_field',
    'perl:5.38,vary-one,Empty::Field,1.0,Dep,,,' ,
    '"perl:5.38",vary-one,Empty::Field,1.0,Dep,,,' ,
);
is($empty_field_dup->{rc}, 0, 'empty field: plan_dedup exits cleanly');
is(scalar(@{ $empty_field_dup->{out} }) - 1, 1, 'empty field: equivalent rows deduplicate');
is($empty_field_dup->{out}[1][5], '', 'empty field: parsed empty field is preserved');

my $trailing_empty_dup = run_plan_dedup(
    'trailing_empty',
    'perl:5.38,baseline,Trailing::Empty,1.0,,,,',
    '"perl:5.38",baseline,Trailing::Empty,1.0,,,,',
);
is($trailing_empty_dup->{rc}, 0, 'trailing empty field: plan_dedup exits cleanly');
is(scalar(@{ $trailing_empty_dup->{out} }) - 1, 1,
    'trailing empty field: equivalent rows deduplicate');
is($trailing_empty_dup->{out}[1][7], '', 'trailing empty field is preserved');

my $one_field_diff = run_plan_dedup(
    'one_field_diff',
    'perl:5.38,baseline,Diff::One,1.0,,,,',
    'perl:5.38,baseline,Diff::One,1.1,,,,',
);

my $vary_two_unordered = run_plan_dedup(
    'vary_two_unordered',
    'perl:5.38,vary-two,Pair::Order,1.0,Dep::A,1,Dep::B,2',
    'perl:5.38,vary-two,Pair::Order,1.0,Dep::B,2,Dep::A,1',
);
is($vary_two_unordered->{rc}, 0, 'vary-two unordered pair: plan_dedup exits cleanly');
is(scalar(@{ $vary_two_unordered->{out} }) - 1, 1,
    'vary-two dependency pair order does not create a second logical test');
is(scalar(@{ $vary_two_unordered->{dup} }) - 1, 1,
    'vary-two reversed pair is accounted for as a duplicate');

is(
    canonical_row_key(['perl:5.38', 'vary-two', 'Pair::Order', '1.0', 'Dep::A', '1', 'Dep::B', '2']),
    canonical_row_key(['perl:5.38', 'vary-two', 'Pair::Order', '1.0', 'Dep::B', '2', 'Dep::A', '1']),
    'canonical identity treats vary-two dependency tuples as unordered',
);
is($one_field_diff->{rc}, 0, 'one-field difference: plan_dedup exits cleanly');
is(scalar(@{ $one_field_diff->{out} }) - 1, 2,
    'one-field difference: rows remain distinct');

my $malformed_input = File::Spec->catfile($tmp, 'malformed.in.csv');
my $malformed_out   = File::Spec->catfile($tmp, 'malformed.out.csv');
write_file(
    $malformed_input,
    csv_row(@schema) . qq{\nperl:5.38,baseline,"Bad,1.0,,,,\n},
);
my @bad_cmd = (
    $^X,
    File::Spec->catfile($root, 'tools', 'plan_dedup.pl'),
    '--input', $malformed_input,
    '--output', $malformed_out,
    '--no-verbose',
);
my $bad_output = qx{@bad_cmd 2>&1};
my $bad_rc = $? >> 8;
isnt($bad_rc, 0, 'malformed CSV is rejected');
like($bad_output, qr/CSV|parse|quoted|malformed|line/i,
    'malformed CSV rejection explains a parse problem');

done_testing;
