package Smoker::AuditIO;
use strict;
use warnings;
use Exporter 'import';
use Text::CSV;
use JSON::PP;
use File::Path qw(make_path);
use Getopt::Long qw(GetOptionsFromArray);

our @EXPORT_OK = qw(options read_csv write_csv read_text write_text new_output
    require_evidence tuple tuple_values tuple_cmp count_rows ranked_counts
    report_counts prerequisite plan_fields children);
my $json = JSON::PP->new->allow_nonref;

sub options {
    my (@required) = @_;
    my (%args, $help);
    Getopt::Long::Configure('no_auto_abbrev', 'no_ignore_case');
    my $usage = "Usage: $0 " . join(' ', map { "--$_ PATH" } @required) . "\n";
    GetOptionsFromArray(\@ARGV, \%args, (map { "$_=s" } @required), 'help' => \$help)
        or die $usage;
    if ($help) { print $usage; exit 0; }
    die $usage if @ARGV || grep { !defined $args{$_} } @required;
    return \%args;
}

sub read_csv {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!\n";
    my $csv = Text::CSV->new({ binary => 1, auto_diag => 2 });
    my $fields = $csv->getline($fh) or die "missing CSV header: $path\n";
    $csv->column_names(@$fields);
    my @rows;
    while (my $row = $csv->getline_hr($fh)) { push @rows, $row; }
    close $fh or die "cannot close $path: $!\n";
    return (\@rows, $fields);
}

sub write_csv {
    my ($path, $fields, $rows, $eol) = @_;
    # Python csv's default is CRLF and minimal quoting; inventory uses LF.
    my $csv = Text::CSV->new({binary => 1, auto_diag => 2,
        eol => ($eol // "\r\n"), quote_space => 0, quote_empty => 0});
    open my $fh, '>:encoding(UTF-8)', $path or die "cannot write $path: $!\n";
    $csv->print($fh, $fields);
    for my $row (@$rows) {
        my @values = ref($row) eq 'HASH' ? map { $row->{$_} } @$fields : @$row;
        $csv->print($fh, \@values);
    }
    close $fh or die "cannot close $path: $!\n";
}

sub read_text {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!\n";
    local $/;
    my $text = <$fh> // '';
    close $fh or die "cannot close $path: $!\n";
    return $text;
}

sub write_text {
    my ($path, $text) = @_;
    open my $fh, '>:encoding(UTF-8)', $path or die "cannot write $path: $!\n";
    print {$fh} $text or die "cannot write $path: $!\n";
    close $fh or die "cannot close $path: $!\n";
}

sub new_output {
    my ($path) = @_;
    die "output already exists: $path\n" if -e $path || -l $path;
    make_path($path);
}

sub require_evidence {
    my ($batch) = @_;
    die "batch validation did not pass: $batch\n"
        unless index(read_text("$batch/validation_evidence.txt"), 'Assessment: PASS') >= 0;
    die "classification evidence did not pass: $batch\n"
        unless index(read_text("$batch/result_classification_audit.txt"), 'Classification evidence: PASS') >= 0;
}

# JSON array keys preserve exact field boundaries, including embedded separators.
sub tuple { return $json->encode([@_]); }
sub tuple_values { return @{ $json->decode($_[0]) }; }
sub tuple_cmp {
    my @left = tuple_values($_[0]); my @right = tuple_values($_[1]);
    for my $i (0 .. $#left) {
        my $cmp = $left[$i] cmp $right[$i];
        return $cmp if $cmp;
    }
    return 0;
}

sub count_rows {
    my ($rows, $field) = @_;
    my (%counts, @order);
    for my $row (@$rows) {
        my $label = $row->{$field};
        push @order, $label unless exists $counts{$label};
        ++$counts{$label};
    }
    return (\%counts, \@order);
}

sub ranked_counts {
    my ($counts, $order, $alphabetical) = @_;
    my %position; @position{@$order} = (0 .. $#$order);
    return sort { $counts->{$b} <=> $counts->{$a}
        || ($alphabetical ? $a cmp $b : $position{$a} <=> $position{$b}) } keys %$counts;
}

sub report_counts {
    my ($rows, $field, $width, $alphabetical) = @_;
    my ($counts, $order) = count_rows($rows, $field);
    return map { sprintf('%*d  %s', $width, $counts->{$_}, $_) }
        ranked_counts($counts, $order, $alphabetical);
}

sub prerequisite {
    my ($note) = @_;
    return $1 if $note =~ /Missing prerequisite: (.+?)(?:;|$)/;
    die "unparseable missing-prerequisite note: $note\n";
}

sub plan_fields { return qw(base mode module version dep_one dep_one_version dep_two dep_two_version); }

sub children {
    my ($dir) = @_;
    opendir my $dh, $dir or die "cannot read directory $dir: $!\n";
    # Retain directory iteration order for the dependency builder's tie behavior.
    my @names = grep { $_ ne '.' && $_ ne '..' } readdir $dh;
    closedir $dh or die "cannot close directory $dir: $!\n";
    return map { "$dir/$_" } @names;
}
1;
