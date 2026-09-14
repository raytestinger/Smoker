package Smoker::TestBatch;

use strict;
use warnings;
use Exporter 'import';
use File::Path qw(make_path);
use File::Spec;
use Text::CSV;

our @EXPORT_OK = qw(make_batch read_text);

sub _write {
    my ($path, $text) = @_;
    open my $fh, '>', $path or die "write $path: $!";
    print {$fh} $text;
    close $fh or die "close $path: $!";
}

sub read_text {
    my ($path) = @_;
    open my $fh, '<', $path or die "read $path: $!";
    local $/;
    my $text = <$fh>;
    close $fh;
    return $text;
}

sub make_batch {
    my ($root, %args) = @_;
    my $batch = File::Spec->catdir($root, 'batch');
    my $run = File::Spec->catdir($batch, 'runs', '000001');
    make_path($run);

    my $rc = $args{rc};
    my $status = $args{status};
    my $note = $args{note} // '';
    my $subtype = $args{subtype} // '';
    my $batch_name = 'batch';
    my $plan_header = "base,mode,module,version,dep_one,dep_one_version,dep_two,dep_two_version\n";
    my $plan_row = "perl:5.38,baseline,Example::Module,1.0,,,,\n";
    _write(File::Spec->catfile($batch, 'original_plan.csv'), $plan_header . $plan_row);
    _write(File::Spec->catfile($batch, 'plan_deduplicated.csv'), $plan_header . $plan_row);
    _write(File::Spec->catfile($batch, 'skipped_dup.csv'), $plan_header);
    _write(File::Spec->catfile($batch, 'batch_info.txt'), "batch=batch\n");

    my @header = qw(run_id batch base mode module version dep_one dep_one_version dep_two dep_two_version status rc start_ts end_ts elapsed_s run_dir note);
    my @row = ('000001', $batch_name, 'perl:5.38', 'baseline', 'Example::Module', '1.0', '', '', '', '', $status, $rc,
        '2026-01-01T00:00:00Z', '2026-01-01T00:00:01Z', '1.000000', $run, $note);
    my $csv = Text::CSV->new({ binary => 1, eol => "\n" });
    open my $sfh, '>', File::Spec->catfile($batch, 'summary.csv') or die $!;
    $csv->print($sfh, \@header);
    $csv->print($sfh, \@row);
    close $sfh;

    _write(File::Spec->catfile($run, 'rc.code'), "$rc\n");
    my @meta = map { $header[$_] . '=' . $row[$_] } 0 .. $#header;
    _write(File::Spec->catfile($run, 'result.meta'), join("\n", @meta) . "\nsubtype=$subtype\n");
    _write(File::Spec->catfile($run, '00_command.txt'), "fake command\n");
    _write(
        File::Spec->catfile($run, 'execution_trail.audit'),
        "record=framework_execution_trail\n"
            . "scope=factual_producer_execution_record\n"
            . "run_id=000001\n"
            . "run_dir=$run\n"
            . "rc_file=rc.code\n"
            . "result_meta=result.meta\n"
            . "command_file=00_command.txt\n"
            . "summary_file=summary.csv\n",
    );
    _write(File::Spec->catfile($run, 'run.out'), $args{evidence} // "ordinary diagnostic evidence\n");
    if ($args{evidence_file}) {
        _write(File::Spec->catfile($run, $args{evidence_file}), $args{evidence_file_text} // $args{evidence} // "evidence\n");
    }

    _write(File::Spec->catfile($batch, 'result_classification_audit.txt'),
        "Classification evidence: PASS\nClassified: 1\nUnclassified: 0\nSUPPORTED: 1\nINDETERMINATE: 0\nUNSUPPORTED: 0\n");
    return ($batch, $run);
}

1;
