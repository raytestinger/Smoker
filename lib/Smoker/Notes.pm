package Smoker::Notes;

use strict;
use warnings;

use File::Spec;

sub dependency_version {
    my ($class, $module, $version) = @_;
    return '' unless defined $module && $module ne '';
    return '' unless defined $version && $version ne '';
    return "Dependency version $module $version requested";
}

sub unavailable {
    my ($class, $module, $version, $offered_version) = @_;

    return '' unless defined $module && $module ne '';
    return '' unless defined $version && $version ne '';

    my @parts = ("$module $version not found in CPAN index");
    if (defined $offered_version && $offered_version ne '') {
        push @parts,
            "CPAN index offered $module $offered_version, not requested version $version";
    }

    return $class->finalize(@parts);
}

sub failure {
    my ($class, $message) = @_;
    return $class->_clean($message);
}

sub dependency_apply_failed {
    my ($class, $module, $version, $rc, $kind, $detail) = @_;
    my $spec = join(' ', grep { defined $_ && $_ ne '' } $module, $version);
    return $class->phase_failure(
        phase   => 'dependency',
        subject => $spec,
        rc      => $rc,
        kind    => $kind,
        detail  => $detail,
    );
}

sub dependency_verify_failed {
    my ($class, $module, $version) = @_;
    my $spec = join(' ', grep { defined $_ && $_ ne '' } $module, $version);
    return $class->failure("Dependency version $spec did not remain installed");
}

sub target_failed {
    my ($class, $module, $version, $rc, $kind, $detail) = @_;
    my $spec = join(' ', grep { defined $_ && $_ ne '' } $module, $version);
    return $class->phase_failure(
        phase   => 'target',
        subject => $spec,
        rc      => $rc,
        kind    => $kind,
        detail  => $detail,
    );
}

sub phase_failure {
    my ($class, %args) = @_;

    my $phase   = $args{phase}   // 'target';
    my $subject = $args{subject} // '';
    my $rc      = defined $args{rc} ? $args{rc} : '';
    my $kind    = $args{kind}    // '';
    my $detail  = $class->_clean($args{detail});

    if ($kind eq 'missing_prerequisite') {
        return $detail ne ''
            ? "Missing prerequisite: $detail"
            : 'A required prerequisite was not available';
    }

    if ($kind eq 'configure') {
        return $subject ne ''
            ? "Configuration failed for $subject"
            : 'Configuration failed';
    }

    if ($kind eq 'fetch') {
        return $subject ne ''
            ? "Download failed for $subject"
            : 'Download failed';
    }

    if ($kind eq 'test') {
        return $subject ne ''
            ? "Test suite failed for $subject"
            : 'Test suite failed';
    }

    if ($kind eq 'build') {
        return $subject ne ''
            ? "Build or installation failed for $subject"
            : 'Build or installation failed';
    }

    if ($phase eq 'dependency') {
        my $message = $subject ne ''
            ? "Installation failed while applying dependency version $subject"
            : 'Dependency-version installation failed';
        $message .= " (rc=$rc)" if $rc ne '';
        return $message;
    }

    my $message = $subject ne ''
        ? "Target installation/test failed for $subject"
        : 'Target installation/test failed';
    $message .= " (rc=$rc)" if $rc ne '';
    return $message;
}

sub log_limit {
    return 'Build log exceeded safety limit; probable runaway configure/install output';
}

sub tool_missing {
    my ($class, $tool) = @_;
    return $class->failure("Required tool not found in container: $tool");
}

sub collect_note_files {
    my ($class, $run_dir) = @_;
    return () unless defined $run_dir && -d $run_dir;

    opendir my $dh, $run_dir or die "opendir $run_dir: $!";
    my %priority = (
        'timeout.note'     => 10,
        'loglimit.note'    => 20,
        'failure.note'     => 30,
        'unavailable.note' => 40,
        'retry.note'       => 50,
        'dependency.note'  => 60,
    );

    my @names = sort {
        ($priority{$a} // 100) <=> ($priority{$b} // 100)
            || $a cmp $b
    } grep {
        /\.note\z/ && -f File::Spec->catfile($run_dir, $_)
    } readdir $dh;
    closedir $dh or die "closedir $run_dir: $!";

    my @notes;
    for my $name (@names) {
        my $path = File::Spec->catfile($run_dir, $name);
        open my $fh, '<', $path or die "read $path: $!";
        local $/;
        my $text = <$fh> // '';
        close $fh or die "close $path: $!";

        $text = $class->_format_note_file($name, $text);
        push @notes, $text if $text ne '';
    }

    return @notes;
}

sub finalize {
    my ($class, @notes) = @_;

    my @out;
    my %seen;

    for my $note (@notes) {
        next unless defined $note;

        # A caller may pass a previously finalized semicolon-separated note.
        # Splitting here lets us remove duplicates across old and new sources.
        for my $part (split /\s*;\s*/, $note) {
            $part = $class->_clean($part);
            next if $part eq '';

            my $key = lc $part;
            next if $seen{$key}++;
            push @out, $part;
        }
    }

    return join('; ', @out);
}

sub _format_note_file {
    my ($class, $name, $text) = @_;
    $text = $class->_clean($text);
    return '' if $text eq '';

    if ($name eq 'unavailable.note') {
        if ($text =~ /\Aunavailable\s+exact\s+release:\s*requested\s+(.+?)\@([^;\s]+)\s*;\s*CPAN\s+index\s+offered\s+\1\s+([^,;\s]+),\s*not\s+requested\s+version\s+\2\z/i) {
            return $class->unavailable($1, $2, $3);
        }

        if ($text =~ /\Aunavailable\s+exact\s+release:\s*requested\s+(.+?)\@([^;\s]+)\z/i) {
            return $class->unavailable($1, $2, '');
        }

        if ($text =~ /\Aunavailable\s+release:\s*(.+?)\@([^\s;]+)\z/i) {
            return $class->unavailable($1, $2, '');
        }
    }

    return $text;
}

sub _clean {
    my ($class, $text) = @_;
    return '' unless defined $text;

    $text =~ s/\r\n?/\n/g;
    $text =~ s/^\s+//;
    $text =~ s/\s+$//;
    $text =~ s/\s*\n\s*/; /g;
    $text =~ s/[\t ]+/ /g;
    $text =~ s/\s*;\s*/; /g;
    $text =~ s/(?:;\s*)+\z//;

    return $text;
}

1;
