package Smoker::PlanCSV;

use strict;
use warnings;

use Exporter qw(import);
use Text::CSV;

our @EXPORT_OK = qw(
    canonical_row_key
    deduplicate_csv
    deduplicate_csv_preserving_comments
    row_is_comment
    read_csv_file
    write_csv_row
);

sub _csv {
    my (%args) = @_;

    my $csv = Text::CSV->new({
        binary         => 1,
        auto_diag      => 0,
        blank_is_undef => 0,
        strict         => 1,
        defined $args{eol} ? (eol => $args{eol}) : (),
    });

    die "ERROR: cannot create CSV parser\n"
        unless $csv;

    return $csv;
}

sub read_csv_file {
    my (%args) = @_;

    my $path            = $args{path}
        or die "ERROR: read_csv_file requires path\n";
    my $expected_header = $args{expected_header};
    my $reject_blank    = $args{reject_blank} // 0;

    my $csv = _csv();

    open my $fh, '<:encoding(UTF-8)', $path
        or die "ERROR: cannot read CSV $path: $!\n";

    my $header = $csv->getline($fh);
    _die_csv_error($csv, $path, 1) unless $header;
    $header->[0] =~ s/^\x{FEFF}// if defined $header->[0];

    if ($expected_header) {
        die "ERROR: expected " . scalar(@$expected_header)
            . " header columns in $path, found " . scalar(@$header) . "\n"
            unless @$header == @$expected_header;

        for my $i (0 .. $#$expected_header) {
            die "ERROR: unexpected header column " . ($i + 1)
                . " in $path: expected '$expected_header->[$i]', "
                . "found '" . ($header->[$i] // '') . "'\n"
                unless ($header->[$i] // '') eq $expected_header->[$i];
        }
    }

    my @rows;
    my $line_number = 1;

    while (1) {
        my $row = $csv->getline($fh);

        if (!$row) {
            _finish_or_die($csv, $path, $line_number);
            last;
        }

        $line_number = $csv->record_number + 1;

        if (_row_is_blank($row)) {
            die "ERROR: blank row at input record " . (scalar(@rows) + 2)
                . " in $path\n"
                if $reject_blank;
            next;
        }

        die "ERROR: input record " . (scalar(@rows) + 2)
            . " in $path has " . scalar(@$row)
            . " columns; expected " . scalar(@$header) . "\n"
            unless @$row == @$header;

        push @rows, [map { defined $_ ? $_ : '' } @$row];
    }

    close $fh
        or die "ERROR: cannot close CSV $path: $!\n";

    return ($header, \@rows);
}

sub deduplicate_csv {
    my (%args) = @_;

    my $source_path     = $args{source_path}
        or die "ERROR: deduplicate_csv requires source_path\n";
    my $output_path     = $args{output_path}
        or die "ERROR: deduplicate_csv requires output_path\n";
    my $duplicates_path = $args{duplicates_path};

    my ($header, $rows) = read_csv_file(
        path            => $source_path,
        expected_header => $args{expected_header},
        reject_blank    => $args{reject_blank} // 0,
    );

    open my $out, '>:encoding(UTF-8)', $output_path
        or die "ERROR: cannot write deduplicated plan $output_path: $!\n";
    write_csv_row($out, $header);

    my $dup;
    if (defined $duplicates_path && length $duplicates_path) {
        open $dup, '>:encoding(UTF-8)', $duplicates_path
            or die "ERROR: cannot write duplicate report $duplicates_path: $!\n";
        write_csv_row($dup, $header);
    }

    my %seen;
    my ($unique_rows, $duplicate_rows) = (0, 0);

    for my $row (@$rows) {
        my $key = canonical_row_key($row);

        if ($seen{$key}++) {
            ++$duplicate_rows;
            write_csv_row($dup, $row) if $dup;
            next;
        }

        ++$unique_rows;
        write_csv_row($out, $row);
    }

    close $out
        or die "ERROR: cannot close deduplicated plan $output_path: $!\n";

    if ($dup) {
        close $dup
            or die "ERROR: cannot close duplicate report $duplicates_path: $!\n";
    }

    return (scalar(@$rows), $unique_rows, $duplicate_rows);
}

sub deduplicate_csv_preserving_comments {
    my (%args) = @_;

    my $source_path     = $args{source_path}
        or die "ERROR: deduplicate_csv_preserving_comments requires source_path\n";
    my $output_path     = $args{output_path}
        or die "ERROR: deduplicate_csv_preserving_comments requires output_path\n";
    my $duplicates_path = $args{duplicates_path}
        or die "ERROR: deduplicate_csv_preserving_comments requires duplicates_path\n";

    open my $in, '<:encoding(UTF-8)', $source_path
        or die "ERROR: cannot read plan $source_path: $!\n";

    open my $out, '>:encoding(UTF-8)', $output_path
        or die "ERROR: cannot write deduplicated plan $output_path: $!\n";

    open my $dup, '>:encoding(UTF-8)', $duplicates_path
        or die "ERROR: cannot write duplicate report $duplicates_path: $!\n";

    my $header_line = <$in>;
    die "ERROR: plan is empty: $source_path\n"
        unless defined $header_line;

    my $header = _parse_csv_line($header_line, $source_path, 1);
    write_csv_row($out, $header);
    write_csv_row($dup, $header);

    my %seen;
    my ($input_rows, $unique_rows, $duplicate_rows) = (0, 0, 0);
    my $line_number = 1;

    while (my $line = <$in>) {
        ++$line_number;

        if ($line =~ /^\s*$/) {
            print {$out} $line
                or die "ERROR: cannot write $output_path: $!\n";
            next;
        }

        my $row = _parse_csv_line($line, $source_path, $line_number);

        if (row_is_comment($row)) {
            print {$out} $line
                or die "ERROR: cannot write $output_path: $!\n";
            next;
        }

        die "ERROR: input line $line_number in $source_path has "
            . scalar(@$row) . " columns; expected " . scalar(@$header) . "\n"
            unless @$row == @$header;

        ++$input_rows;

        my $key = canonical_row_key($row);
        if ($seen{$key}++) {
            ++$duplicate_rows;
            write_csv_row($dup, $row);
            next;
        }

        ++$unique_rows;
        write_csv_row($out, $row);
    }

    close $in
        or die "ERROR: cannot close plan $source_path: $!\n";
    close $out
        or die "ERROR: cannot close deduplicated plan $output_path: $!\n";
    close $dup
        or die "ERROR: cannot close duplicate report $duplicates_path: $!\n";

    return ($input_rows, $unique_rows, $duplicate_rows);
}

sub canonical_row_key {
    my ($fields) = @_;

    die "ERROR: canonical_row_key requires an array reference\n"
        unless ref($fields) eq 'ARRAY';

    my @canonical = map { defined $_ ? $_ : '' } @$fields;

    if (@canonical == 8 && $canonical[1] eq 'vary-two') {
        my @left  = @canonical[4, 5];
        my @right = @canonical[6, 7];
        my $left_key  = _length_prefixed_key(\@left);
        my $right_key = _length_prefixed_key(\@right);

        if ($right_key lt $left_key) {
            @canonical[4, 5, 6, 7] = (@right, @left);
        }
    }

    return scalar(@canonical) . ':' . join '', map {
        my $value = defined $_ ? $_ : '';
        length($value) . ':' . $value;
    } @canonical;
}

sub row_is_comment {
    my ($fields) = @_;

    return 0 unless ref($fields) eq 'ARRAY' && @$fields;
    my $first = defined $fields->[0] ? $fields->[0] : '';
    return $first =~ /^\s*#/ ? 1 : 0;
}

sub _length_prefixed_key {
    my ($fields) = @_;
    return join '', map { length($_) . ':' . $_ } @$fields;
}

sub write_csv_row {
    my ($fh, $fields) = @_;

    my $csv = _csv(eol => "\n");
    $csv->print($fh, [map { defined $_ ? $_ : '' } @$fields])
        or die "ERROR: cannot write CSV row: " . $csv->error_diag . "\n";
}

sub _finish_or_die {
    my ($csv, $path, $line_number) = @_;

    if (!$csv->eof) {
        _die_csv_error($csv, $path, $line_number);
    }

    my ($code) = $csv->error_diag;
    if (defined $code && $code != 2012) {
        _die_csv_error($csv, $path, $line_number);
    }
}

sub _die_csv_error {
    my ($csv, $path, $line_number) = @_;

    my ($code, $message, $position, $record) = $csv->error_diag;
    $message ||= 'unknown CSV parse error';
    $record  ||= $line_number;

    die "ERROR: malformed CSV in $path at record $record: "
        . "$message"
        . (defined $position ? " at position $position" : '')
        . "\n";
}

sub _parse_csv_line {
    my ($line, $path, $line_number) = @_;

    my $csv = _csv();
    if (!$csv->parse($line)) {
        _die_csv_error($csv, $path, $line_number);
    }

    return [map { defined $_ ? $_ : '' } $csv->fields];
}

sub _row_is_blank {
    my ($row) = @_;

    for my $value (@$row) {
        return 0 if defined $value && $value ne '';
    }

    return 1;
}

1;
