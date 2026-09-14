package Smoker::Inner;

use strict;
use warnings;

use Exporter 'import';
use File::Copy qw(copy);
use File::Find qw(find);
use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempfile);
use POSIX qw(_exit WNOHANG);
use Smoker::Notes ();
use version ();

our @EXPORT_OK = qw(run run_from_env);

sub run_from_env {
    return run(
        module          => $ENV{SMOKER_MODULE}          // '',
        version         => $ENV{SMOKER_VERSION}         // '',
        mode            => $ENV{SMOKER_MODE}            // 'baseline',
        dep_one         => $ENV{SMOKER_DEP_ONE}         // '',
        dep_one_version => $ENV{SMOKER_DEP_ONE_VERSION} // '',
        dep_two         => $ENV{SMOKER_DEP_TWO}         // '',
        dep_two_version => $ENV{SMOKER_DEP_TWO_VERSION} // '',
        run_dir         => $ENV{SMOKER_RUN_DIR}         // '/work/run',
    );
}

sub run {
    my (%args) = @_;

    my $module  = $args{module}  // '';
    my $version = $args{version} // '';
    my $mode    = $args{mode}    // 'baseline';

    my $dep1 = defined $args{dep_one} ? $args{dep_one}
             : defined $args{dep1}    ? $args{dep1}
             : '';

    my $ver1 = defined $args{dep_one_version} ? $args{dep_one_version}
             : defined $args{ver1}            ? $args{ver1}
             : '';

    my $dep2 = defined $args{dep_two} ? $args{dep_two}
             : defined $args{dep2}    ? $args{dep2}
             : '';

    my $ver2 = defined $args{dep_two_version} ? $args{dep_two_version}
             : defined $args{ver2}            ? $args{ver2}
             : '';

    my $run_dir = $args{run_dir} || '/work/run';
    my $modspec = $module . ($version ne '' ? '@' . $version : '');

    my $build_log    = File::Spec->catfile($run_dir, 'build.log');
    my $artifact_dir = File::Spec->catdir($run_dir, 'reports');
    my $artifact_err = File::Spec->catfile($artifact_dir, 'artifact_copy.err');
    my $artifact_diag = File::Spec->catfile($artifact_dir, 'diag.txt');

    make_path($artifact_dir);
    _truncate_file($build_log);
    _truncate_file($artifact_err);
    _truncate_file($artifact_diag);

    my $log = sub {
        my ($message) = @_;
        $message = '' unless defined $message;
        print STDOUT $message, "\n";
        open my $fh, '>>', $build_log
            or die "cannot append $build_log: $!\n";
        print {$fh} $message, "\n";
        close $fh or die "cannot close $build_log: $!\n";
    };

    my $trace = sub {
        return unless defined $ENV{SMOKER_TRACE_VERSION}
            && $ENV{SMOKER_TRACE_VERSION} ne '';
        $log->("[trace-version] " . join('', @_));
    };

    $log->("[inner] Starting Smoker::Inner");
    $log->("[inner] module=$module version=$version");
    $log->("[inner] mode=$mode dep1=$dep1 ver1=$ver1 dep2=$dep2 ver2=$ver2");
    $log->("[inner] PWD=" . _cwd());
    $log->("[inner] HOME=" . ($ENV{HOME} // ''));
    $log->("[inner] ARTIFACT_DIR=$artifact_dir");
    $trace->("enabled SMOKER_TRACE_VERSION=<" . ($ENV{SMOKER_TRACE_VERSION} // '') . ">");

    my $cpanm = _find_in_path('cpanm');
    if (!defined $cpanm) {
        $log->("[inner] cpanm not found in container");
        _write_note_file($run_dir, 'failure.note', Smoker::Notes->tool_missing('cpanm'), $log);
        return 127;
    }

    $log->("[inner] Using cpanm at $cpanm");
    $trace->("perl=" . ($^X // 'perl'));
    $trace->("perl_version=$]");

    delete @ENV{qw(PERL_CPANM_OPT PERL_MM_OPT PERL_MB_OPT)};

    my $local_lib = $ENV{SMOKER_LOCAL_LIB} || '/tmp/perl5';
    make_path($local_lib);

    $ENV{PERL_LOCAL_LIB_ROOT} = $local_lib;
    $ENV{PERL_MB_OPT} = "--install_base $local_lib";
    $ENV{PERL_MM_OPT} = "INSTALL_BASE=$local_lib";

    my $local_lib_perl5 = File::Spec->catdir($local_lib, 'lib', 'perl5');
    $ENV{PERL5LIB} = join(
        ':',
        grep { defined $_ && $_ ne '' }
        $local_lib_perl5,
        $ENV{PERL5LIB},
    );
    $ENV{PATH} = join(
        ':',
        grep { defined $_ && $_ ne '' }
        File::Spec->catdir($local_lib, 'bin'),
        $ENV{PATH},
    );

    unshift @INC, $local_lib_perl5
        unless grep { defined $_ && $_ eq $local_lib_perl5 } @INC;

    $log->("[inner] Using local::lib style install base: $local_lib");
    $log->("[inner] PERL5LIB=$ENV{PERL5LIB}");

    my @cpanm_args;
    my @live_cpanm_args;

    my $local_mirror = $ENV{SMOKER_LOCAL_MIRROR} // '';
    my $mirror_index = $local_mirror ne ''
        ? File::Spec->catfile($local_mirror, 'modules', '02packages.details.txt.gz')
        : '';
    my $live_mirror = $ENV{SMOKER_LIVE_MIRROR} || 'https://cpan.metacpan.org';

    if ($local_mirror ne '' && -f $mirror_index) {
        push @cpanm_args,
            '--mirror', "file://$local_mirror",
            '--mirror-only';

        $log->("[inner] Using local CPAN mirror only: $local_mirror");
    }
    else {
        push @cpanm_args, '--mirror', $live_mirror;
        $log->("[inner] No local CPAN mirror available; using live CPAN: $live_mirror");
    }

    push @live_cpanm_args, '--mirror', $live_mirror;
    $log->("[inner] Live CPAN fallback mirror: $live_mirror");

    my $tarball_cache = $ENV{SMOKER_TARBALL_CACHE} // '';
    if ($tarball_cache ne '') {
        make_path($tarball_cache);
        push @cpanm_args,      '--save-dists', $tarball_cache;
        push @live_cpanm_args, '--save-dists', $tarball_cache;
        $log->("[inner] Saving cpanm tarballs to $tarball_cache");
    }
    else {
        $log->("[inner] SMOKER_TARBALL_CACHE not set; tarballs will not be preserved");
    }

    $trace->("initial local CPANM_ARGS=<" . join(' ', @cpanm_args) . ">");
    $trace->("initial live CPANM_ARGS=<" . join(' ', @live_cpanm_args) . ">");

    my $ctx = {
        cpanm           => $cpanm,
        cpanm_args      => \@cpanm_args,
        live_cpanm_args => \@live_cpanm_args,
        build_log       => $build_log,
        log             => $log,
        trace           => $trace,
        run_dir         => $run_dir,
    };

    my $dependency_version_rc = _apply_dependency_version($ctx, $dep1, $ver1);
    if ($dependency_version_rc != 0) {
        if ($dependency_version_rc != 111 && $dependency_version_rc != 112) {
            _write_note_file(
                $run_dir,
                'failure.note',
                Smoker::Notes->dependency_apply_failed($dep1, $ver1, $dependency_version_rc, $ctx->{last_failure_kind}, $ctx->{last_failure_detail}),
                $log,
            );
        }
        $log->("[inner] rc=$dependency_version_rc");
        return $dependency_version_rc;
    }

    $dependency_version_rc = _apply_dependency_version($ctx, $dep2, $ver2);
    if ($dependency_version_rc != 0) {
        if ($dependency_version_rc != 111 && $dependency_version_rc != 112) {
            _write_note_file(
                $run_dir,
                'failure.note',
                Smoker::Notes->dependency_apply_failed($dep2, $ver2, $dependency_version_rc, $ctx->{last_failure_kind}, $ctx->{last_failure_detail}),
                $log,
            );
        }
        $log->("[inner] rc=$dependency_version_rc");
        return $dependency_version_rc;
    }

    $log->("[inner] Installing target dependencies for $modspec");
    $trace->("before installdeps MODSPEC=<$modspec>");
    _trace_module_state($ctx, 'before installdeps dep1', $dep1, $ver1);
    _trace_module_state($ctx, 'before installdeps dep2', $dep2, $ver2);

    my $deps_rc = _run_cpanm_local_then_live(
        $ctx,
        label => "target dependencies for $modspec",
        args  => [ '--installdeps', $modspec ],
    );

    if ($deps_rc == 112) {
        $log->("[inner] target dependency installation aborted by build.log safety limit");
        $log->("[inner] rc=112");
        _write_note_file($run_dir, 'loglimit.note', Smoker::Notes->log_limit(), $log);
        _collect_artifacts($artifact_dir, $artifact_err, $artifact_diag, $log);
        return 112;
    }

    if ($deps_rc != 0) {
        $log->("[inner] warning: installdeps failed for $modspec; continuing to target install/test");
    }

    $trace->("after installdeps MODSPEC=<$modspec>");
    _trace_module_state($ctx, 'after installdeps dep1', $dep1, $ver1);
    _trace_module_state($ctx, 'after installdeps dep2', $dep2, $ver2);

    if (!_verify_dependency_version($ctx, $dep1, $ver1)) {
        _write_note_file($run_dir, 'failure.note', Smoker::Notes->dependency_verify_failed($dep1, $ver1), $log);
        $log->("[inner] rc=2");
        return 2;
    }

    if (!_verify_dependency_version($ctx, $dep2, $ver2)) {
        _write_note_file($run_dir, 'failure.note', Smoker::Notes->dependency_verify_failed($dep2, $ver2), $log);
        $log->("[inner] rc=2");
        return 2;
    }

    $log->("[inner] Installing/testing target $modspec");
    $trace->("before target install MODSPEC=<$modspec>");
    _trace_module_state($ctx, 'before target install dep1', $dep1, $ver1);
    _trace_module_state($ctx, 'before target install dep2', $dep2, $ver2);

    my $rc = _run_cpanm_local_then_live(
        $ctx,
        label => "target $modspec",
        args  => [ $modspec ],
    );

    if ($rc == 111) {
        my $note = $ctx->{unavailable_note} // '';
        my $suffix = $note ne '' ? "; $note" : '';
        $log->("[inner] unavailable release: $modspec$suffix");
        _write_unavailable_note($ctx, "unavailable exact release: requested $modspec" . ($note ne '' ? "; $note" : ''));
    }

    $trace->("after target install MODSPEC=<$modspec> rc=<$rc>");
    _trace_module_state($ctx, 'after target install dep1', $dep1, $ver1);
    _trace_module_state($ctx, 'after target install dep2', $dep2, $ver2);

    if ($rc == 112) {
        _write_note_file($run_dir, 'loglimit.note', Smoker::Notes->log_limit(), $log);
    }
    elsif ($rc != 0 && $rc != 111) {
        _write_note_file(
            $run_dir,
            'failure.note',
            Smoker::Notes->target_failed($module, $version, $rc, $ctx->{last_failure_kind}, $ctx->{last_failure_detail}),
            $log,
        );
    }

    $log->("[inner] rc=$rc");
    _collect_artifacts($artifact_dir, $artifact_err, $artifact_diag, $log);

    return $rc;
}

sub _apply_dependency_version {
    my ($ctx, $mod, $ver) = @_;

    $ctx->{trace}->("apply_dependency_version start module=<$mod> version=<$ver>");

    if ($mod eq '' || $ver eq '') {
        $ctx->{trace}->("apply_dependency_version skipped module=<$mod> version=<$ver>");
        return 0;
    }

    my $spec = "$mod\@$ver";
    $ctx->{log}->("[inner] Applying dependency version $spec");
    $ctx->{trace}->(
        "apply_dependency_version cpanm spec=<$spec> args=<"
        . join(' ', @{ $ctx->{cpanm_args} })
        . ">"
    );
    _trace_module_state($ctx, 'apply_dependency_version before cpanm', $mod, $ver);

    my $rc = _run_cpanm_local_then_live(
        $ctx,
        label => "dependency version $spec",
        args  => [ $spec ],
    );

    if ($rc != 0) {
        $ctx->{log}->("[inner] failed applying dependency version $spec");

        if ($rc == 111) {
            my $note = $ctx->{unavailable_note} // '';
            my $suffix = $note ne '' ? "; $note" : '';
            $ctx->{log}->("[inner] unavailable release: $spec$suffix");
            _write_unavailable_note($ctx, "unavailable exact release: requested $spec" . ($note ne '' ? "; $note" : ''));
            _trace_module_state($ctx, 'apply_dependency_version unavailable release', $mod, $ver);
            return 111;
        }

        _trace_module_state($ctx, 'apply_dependency_version after failed cpanm', $mod, $ver);
        return 1;
    }

    _trace_module_state($ctx, 'apply_dependency_version after cpanm', $mod, $ver);

    if (!_verify_dependency_version($ctx, $mod, $ver)) {
        $ctx->{log}->("[inner] refusing to continue because requested dependency version did not remain installed");
        return 1;
    }

    return 0;
}

sub _verify_dependency_version {
    my ($ctx, $mod, $want) = @_;

    $ctx->{trace}->("verify_dependency_version start module=<$mod> want=<$want>");

    if ($mod eq '' || $want eq '') {
        $ctx->{trace}->("verify_dependency_version skipped module=<$mod> want=<$want>");
        return 1;
    }

    _trace_module_state($ctx, 'verify_dependency_version before compare', $mod, $want);

    my ($rc, $got) = _show_installed_version($mod);

    if ($rc != 0) {
        $ctx->{log}->("[inner] dependency version verification failed for $mod rc=$rc");
        $ctx->{log}->("[inner] loader said: $got");
        return 0;
    }

    $ctx->{trace}->("verify_dependency_version compare module=<$mod> want=<$want> got=<$got>");

    # Some installable distributions expose no package $VERSION for the
    # requested module.  cpanm has already resolved and installed the exact
    # release, so an absent module version is inconclusive rather than a
    # mismatch.
    if ($got eq 'undef') {
        $ctx->{log}->("[inner] $mod has no package version; exact-release installation cannot be verified locally");
        return 1;
    }

    if (!_versions_match($ctx, $want, $got)) {
        $ctx->{log}->("[inner] dependency version mismatch for $mod: wanted $want got $got");
        _trace_module_state($ctx, 'verify_dependency_version mismatch details', $mod, $want);
        return 0;
    }

    $ctx->{log}->("[inner] verified $mod version $got");
    $ctx->{trace}->("verify_dependency_version success module=<$mod> wanted=<$want> got=<$got>");

    return 1;
}

sub _versions_match {
    my ($ctx, $want, $got) = @_;

    $ctx->{trace}->("versions_match input want=<$want> got=<$got>");

    for ($want, $got) {
        $_ = '' unless defined $_;
        s/^\s+//;
        s/\s+$//;
    }

    # A module can emit warnings while it is loaded for the version probe.
    # _show_installed_version suppresses those warnings, but retain this
    # defensive normalization so only a final version-like token is compared.
    if ($got ne '' && $got !~ /\A(?:undef|v?[0-9][0-9A-Za-z._]*)\z/) {
        if ($got =~ /(?:\A|\R)(v?[0-9][0-9A-Za-z._]*)\s*\z/) {
            $got = $1;
        }
    }

    $ctx->{trace}->("versions_match normalized want=<$want> got=<$got>");

    if ($want eq $got) {
        $ctx->{trace}->("versions_match result=PASS string_equal");
        return 1;
    }

    # Perl versions have multiple equivalent spellings (for example 1.000
    # and 1, or v1.0.10 and 1.0.10).  Compare their semantic values while
    # retaining string equality above for unusual historical versions that
    # version.pm cannot parse.
    my ($want_v, $got_v);
    my $parsed = eval {
        $want_v = version->parse($want);
        $got_v  = version->parse($got);
        1;
    };

    if ($parsed && $want_v == $got_v) {
        $ctx->{trace}->("versions_match result=PASS version_equal");
        return 1;
    }

    $ctx->{trace}->("versions_match result=FAIL");
    return 0;
}

sub _trace_module_state {
    my ($ctx, $label, $mod, $want) = @_;

    return unless defined $ENV{SMOKER_TRACE_VERSION}
        && $ENV{SMOKER_TRACE_VERSION} ne '';

    $ctx->{trace}->("$label module=<$mod> want=<$want>");

    if ($mod eq '') {
        $ctx->{trace}->("$label skipped: empty module");
        return;
    }

    my ($got_rc, $got) = _show_installed_version($mod);
    $ctx->{trace}->("$label show_installed_version rc=<$got_rc> raw=<$got>");

    my ($loaded_rc, $loaded) = _show_loaded_file($mod);
    $ctx->{trace}->("$label loaded_file rc=<$loaded_rc> path=<$loaded>");
}

sub _show_installed_version {
    my ($mod) = @_;

    my $code = q{
        my $mod = shift;
        require File::Spec;
        require POSIX;
        my $file = $mod;
        $file =~ s{::}{/}g;
        $file .= ".pm";

        # Loading old modules can print TAP or other chatter.  Keep that out
        # of the machine-readable probe result without changing STDERR's
        # useful require failure diagnostics.
        open my $saved_stdout, ">&", \*STDOUT or die "dup stdout: $!";
        open STDOUT, ">", File::Spec->devnull() or die "silence stdout: $!";
        {
            local $SIG{__WARN__} = sub {};
            require $file;
        }
        open STDOUT, ">&", $saved_stdout or die "restore stdout: $!";

        no strict "refs";
        my $v = ${"${mod}::VERSION"};
        print defined($v) ? $v : "undef";
        close STDOUT or die "flush version probe: $!";

        # Test modules can install END handlers that print TAP or change the
        # process status merely because they were loaded.  The version has
        # already been captured, so bypass module-owned global teardown.
        POSIX::_exit(0);
    };

    return _capture_cmd($^X, '-e', $code, $mod);
}

sub _show_loaded_file {
    my ($mod) = @_;

    my $code = q{
        my $mod = shift;
        my $file = $mod;
        $file =~ s{::}{/}g;
        $file .= ".pm";
        require $file;
        print defined($INC{$file}) ? $INC{$file} : "undef";
    };

    return _capture_cmd($^X, '-e', $code, $mod);
}

sub _run_cpanm_local_then_live {
    my ($ctx, %args) = @_;

    my $label = $args{label} // 'cpanm request';
    my $extra = $args{args}  || [];

    # These fields describe only the current cpanm request.
    delete $ctx->{unavailable_note};
    delete $ctx->{last_failure_kind};
    delete $ctx->{last_failure_detail};

    my $local_offset = _file_size($ctx->{build_log});

    $ctx->{trace}->(
        "cpanm local attempt label=<$label> args=<"
        . join(' ', @{ $ctx->{cpanm_args} }, @$extra)
        . ">"
    );

    my $rc = _run_logged_cmd(
        $ctx->{build_log},
        $ctx->{cpanm}, '-v', '-n',
        @{ $ctx->{cpanm_args} },
        @$extra,
    );

    return 0   if $rc == 0;
    return 112 if $rc == 112;

    if (
        !_release_unavailable_seen($ctx->{build_log}, $local_offset)
        && !_local_mirror_distribution_fetch_failed($ctx->{build_log}, $local_offset)
    ) {
        my ($kind, $detail) = _detect_failure_reason($ctx->{build_log}, $local_offset);
        $ctx->{last_failure_kind}   = $kind   if $kind ne '';
        $ctx->{last_failure_detail} = $detail if $detail ne '';
        $ctx->{trace}->("cpanm local failure was not an unavailable-release error label=<$label> rc=<$rc> kind=<$kind> detail=<$detail>");
        return $rc;
    }

    $ctx->{log}->("[inner] Local MiniCPAN could not resolve $label; retrying exact request against live CPAN");

    my $live_offset = _file_size($ctx->{build_log});

    $ctx->{trace}->(
        "cpanm live fallback label=<$label> args=<"
        . join(' ', @{ $ctx->{live_cpanm_args} }, @$extra)
        . ">"
    );

    my $live_rc = _run_logged_cmd(
        $ctx->{build_log},
        $ctx->{cpanm}, '-v', '-n',
        @{ $ctx->{live_cpanm_args} },
        @$extra,
    );

    if ($live_rc == 0) {
        $ctx->{log}->("[inner] Live CPAN fallback resolved $label");
        return 0;
    }

    return 112 if $live_rc == 112;

    if (_release_unavailable_seen($ctx->{build_log}, $live_offset)) {
        my $offered = _offered_version_note($ctx->{build_log}, $live_offset);
        $ctx->{unavailable_note} = $offered if $offered ne '';

        my $suffix = $offered ne '' ? "; $offered" : '';
        $ctx->{log}->("[inner] Live CPAN also could not resolve $label$suffix");
        return 111;
    }

    my ($kind, $detail) = _detect_failure_reason($ctx->{build_log}, $live_offset);
    $ctx->{last_failure_kind}   = $kind   if $kind ne '';
    $ctx->{last_failure_detail} = $detail if $detail ne '';
    $ctx->{log}->("[inner] Live CPAN fallback failed for $label rc=$live_rc kind=$kind"
        . ($detail ne '' ? " detail=$detail" : ''));
    return $live_rc;
}

sub _local_mirror_distribution_fetch_failed {
    my ($build_log, $offset) = @_;

    $offset = 0 unless defined $offset && $offset >= 0;

    open my $fh, '<', $build_log or return 0;
    seek $fh, $offset, 0 or do {
        close $fh;
        return 0;
    };

    local $/;
    my $text = <$fh> // '';
    close $fh;

    # A MiniCPAN index can retain a package entry while its distribution
    # archive is absent from the mirror.  Retry that exact CPAN distribution
    # against the live mirror.  Do not match arbitrary network downloads made
    # by a distribution's own build (for example an Alien module fetching a
    # native library).
    return $text =~ m{
        (?:Failed\s+to\s+download|Fetching)\s+
        file://[^\s]*/authors/id/[^\s]+\.(?:tar\.gz|tar\.bz2|tar\.xz|tgz|zip)
        (?:\s+\.\.\.\s+FAIL)?
    }ix ? 1 : 0;
}


sub _write_note_file {
    my ($run_dir, $name, $note, $log) = @_;

    return unless defined $run_dir && $run_dir ne '';
    return unless defined $name && $name =~ /\A[A-Za-z0-9_.-]+\.note\z/;
    return unless defined $note && $note ne '';

    my $path = File::Spec->catfile($run_dir, $name);
    open my $fh, '>', $path or do {
        $log->("[inner] warning: cannot write $path: $!") if $log;
        return;
    };

    print {$fh} $note, "\n";
    close $fh or do {
        $log->("[inner] warning: cannot close $path: $!") if $log;
        return;
    };

    $log->("[inner] wrote note: $path") if $log;
}

sub _write_unavailable_note {
    my ($ctx, $note) = @_;
    return unless defined $ctx && ref $ctx eq 'HASH';
    _write_note_file($ctx->{run_dir}, 'unavailable.note', $note, $ctx->{log});
}

sub _offered_version_note {
    my ($build_log, $offset) = @_;

    $offset = 0 unless defined $offset && $offset >= 0;

    open my $fh, '<', $build_log or return '';
    seek $fh, $offset, 0 or do {
        close $fh;
        return '';
    };

    local $/;
    my $text = <$fh> // '';
    close $fh;

    my @matches = $text =~ /Found\s+(\S+)\s+(\S+)\s+which\s+doesn['’]?t\s+satisfy\s+==\s+(\S+)/ig;
    return '' unless @matches >= 3;

    my ($module, $offered, $requested) = @matches[-3, -2, -1];
    $requested =~ s/[.!,;:]\z//;

    return "CPAN index offered $module $offered, not requested version $requested";
}


sub _detect_failure_reason {
    my ($build_log, $offset) = @_;

    $offset = 0 unless defined $offset && $offset >= 0;

    open my $fh, '<', $build_log or return ('', '');
    seek $fh, $offset, 0 or do {
        close $fh;
        return ('', '');
    };

    local $/;
    my $text = <$fh> // '';
    close $fh;

    if ($text =~ /Can't\s+locate\s+([A-Za-z0-9_\/]+\.pm)\s+in\s+\@INC/i) {
        my $module = $1;
        $module =~ s{\.pm\z}{};
        $module =~ s{/}{::}g;
        return ('missing_prerequisite', $module);
    }

    if ($text =~ /(?:prerequisite|dependency)\s+([A-Za-z_][A-Za-z0-9_:]*)\s+(?:is\s+)?(?:not\s+found|missing|not\s+installed)/i) {
        return ('missing_prerequisite', $1);
    }

    if ($text =~ /
        (?:Couldn['’]?t|Could\s+not|Failed\s+to)\s+(?:download|fetch)
        |download\s+(?:error|failed)
        |HTTP\s+(?:failure|error)
        |connection\s+(?:timed\s+out|refused|reset)
        |Temporary\s+failure\s+in\s+name\s+resolution
    /ix) {
        return ('fetch', '');
    }

    if ($text =~ /
        (?:Makefile\.PL|Build\.PL).*(?:failed|exited\s+with)
        |No\s+['"]?Makefile['"]?\s+(?:created|found)
        |Configuration\s+failed
        |Configure\s+failed
        |ERRORS\/WARNINGS\s+FOUND\s+IN\s+PREREQUISITES
    /ixs) {
        return ('configure', '');
    }

    if ($text =~ /
        Test\s+Summary\s+Report
        |Result:\s*FAIL
        |Failed\s+\d+\/\d+\s+test
        |(?:make|Build)\s+test.*(?:failed|error)
        |Tests?\s+failed
    /ixs) {
        return ('test', '');
    }

    if ($text =~ /
        \bmake(?:\[\d+\])?:\s+\*\*\*
        |Build\s+failed
        |Failed\s+to\s+build
        |Failed\s+to\s+install
        |error\s+building
        |Compilation\s+failed
    /ix) {
        return ('build', '');
    }

    return ('', '');
}

sub _release_unavailable_seen {
    my ($build_log, $offset) = @_;

    $offset = 0 unless defined $offset && $offset >= 0;

    open my $fh, '<', $build_log or return 0;
    seek $fh, $offset, 0 or do {
        close $fh;
        return 0;
    };

    local $/;
    my $text = <$fh> // '';
    close $fh;

    return $text =~ /
        Could\ not\ find\ a\ release\ matching
        |Couldn['’]?t\ find\ module\ or\ a\ distribution
        |Could\ not\ find\ module\ or\ a\ distribution
        |No\ matching\ distribution\ found
        |No\ such\ module
        |No\ such\ distribution
        |No\ releases?\ found
        |Finding\ .*?\ on\ metacpan\ failed
        |Skipping\ .*?\ because\ it\ doesn['’]?t\ match\ specified\ version
        |Found\s+\S+\s+(?:\S+\s+)?which\s+doesn['’]?t\s+satisfy\s+\=\=
        |404\ Not\ Found
    /ix ? 1 : 0;
}

sub _file_size {
    my ($path) = @_;

    my @stat = stat $path;
    return @stat ? $stat[7] : 0;
}

sub _run_logged_cmd {
    my ($log_path, @cmd) = @_;

    # Protect the host from distributions whose configure/install scripts
    # print forever (for example, an unanswered interactive prompt).  The
    # limit applies to the complete build.log across all cpanm commands in
    # this run.  Set SMOKER_BUILD_LOG_MAX_BYTES=0 to disable the cap.
    my $max_bytes = 100 * 1024 * 1024;
    if (defined $ENV{SMOKER_BUILD_LOG_MAX_BYTES}
        && $ENV{SMOKER_BUILD_LOG_MAX_BYTES} =~ /\A\d+\z/)
    {
        $max_bytes = 0 + $ENV{SMOKER_BUILD_LOG_MAX_BYTES};
    }

    my $already = _file_size($log_path);
    if ($max_bytes && $already >= $max_bytes) {
        _append_log_limit_notice($log_path, $max_bytes);
        return 112;
    }

    pipe(my $reader, my $writer) or return 255;

    my $pid = fork();
    if (!defined $pid) {
        close $reader;
        close $writer;
        return 255;
    }

    if ($pid == 0) {
        close $reader;

        # Put the command and any descendants in their own process group so
        # a runaway configure script can be terminated as a unit.
        setpgrp(0, 0);

        open STDOUT, '>&', $writer or _exit(255);
        open STDERR, '>&', \*STDOUT or _exit(255);
        close $writer;
        exec { $cmd[0] } @cmd or _exit(255);
    }

    close $writer;
    open my $log_fh, '>>', $log_path or do {
        close $reader;
        kill 'TERM', -$pid;
        waitpid($pid, 0);
        return 255;
    };
    binmode $reader;
    binmode $log_fh;

    my $written = $already;
    my $limited = 0;
    my $buffer;

    while (1) {
        my $n = sysread($reader, $buffer, 64 * 1024);
        if (!defined $n) {
            next if $!{EINTR};
            last;
        }
        last if $n == 0;

        if (!$max_bytes) {
            print {$log_fh} $buffer;
            next;
        }

        my $remaining = $max_bytes - $written;
        if ($remaining > 0) {
            my $chunk = $n <= $remaining
                ? $buffer
                : substr($buffer, 0, $remaining);
            print {$log_fh} $chunk;
            $written += length $chunk;
        }

        if ($written >= $max_bytes) {
            $limited = 1;
            last;
        }
    }

    if ($limited) {
        _append_log_limit_notice_fh($log_fh, $max_bytes);
        close $log_fh;
        close $reader;

        kill 'TERM', -$pid;
        for (1 .. 20) {
            my $done = waitpid($pid, WNOHANG);
            return 112 if $done == $pid;
            select undef, undef, undef, 0.1;
        }
        kill 'KILL', -$pid;
        waitpid($pid, 0);
        return 112;
    }

    close $log_fh;
    close $reader;
    waitpid($pid, 0);
    return _normalize_wait_status($?);
}

sub _append_log_limit_notice {
    my ($log_path, $max_bytes) = @_;

    open my $fh, '>>', $log_path or return;
    _append_log_limit_notice_fh($fh, $max_bytes);
    close $fh;
}

sub _append_log_limit_notice_fh {
    my ($fh, $max_bytes) = @_;

    my $mib = int($max_bytes / (1024 * 1024));
    print {$fh} "\n", "=" x 72, "\n";
    print {$fh} "[inner] Smoker aborted this command: build.log reached its ";
    print {$fh} $mib, " MiB safety limit.\n";
    print {$fh} "[inner] Probable runaway configure/install output or interactive prompt.\n";
    print {$fh} "[inner] rc=112\n";
    print {$fh} "=" x 72, "\n";
}

sub _capture_cmd {
    my (@cmd) = @_;

    my ($fh, $path) = tempfile('smoker-inner-capture-XXXXXX', TMPDIR => 1, UNLINK => 0);
    close $fh;

    my $pid = fork();
    if (!defined $pid) {
        unlink $path;
        return (255, 'fork failed');
    }

    if ($pid == 0) {
        open STDOUT, '>', $path or _exit(255);
        open STDERR, '>&', \*STDOUT or _exit(255);
        exec { $cmd[0] } @cmd or _exit(255);
    }

    waitpid($pid, 0);
    my $rc = _normalize_wait_status($?);

    open my $rfh, '<', $path;
    local $/;
    my $output = $rfh ? (<$rfh> // '') : '';
    close $rfh if $rfh;
    unlink $path;

    $output =~ s/\r?\n\z//;
    return ($rc, $output);
}

sub _collect_artifacts {
    my ($artifact_dir, $artifact_err, $artifact_diag, $log) = @_;

    $log->("[inner] Collecting cpanm artifacts");

    open my $diag, '>', $artifact_diag
        or return;
    print {$diag} "[inner] Collecting cpanm artifacts\n";

    my $home = $ENV{HOME} || '/tmp';
    my $cpanm_root = File::Spec->catdir($home, '.cpanm');

    if (-d $cpanm_root) {
        find(
            {
                no_chdir => 1,
                wanted   => sub {
                    return unless -f $_;
                    return unless /\.(?:rpt|report|json)\z/;
                    print {$diag} "$File::Find::name\n";
                },
            },
            $cpanm_root,
        );
    }

    close $diag;

    my $work_root = File::Spec->catdir($cpanm_root, 'work');
    return unless -d $work_root;

    opendir my $dh, $work_root or return;
    my @dirs = sort grep {
        $_ ne '.'
            && $_ ne '..'
            && -d File::Spec->catdir($work_root, $_)
    } readdir $dh;
    closedir $dh;

    return unless @dirs;

    my $latest = File::Spec->catdir($work_root, $dirs[-1]);
    my $source = File::Spec->catfile($latest, 'build.log');
    return unless -f $source;

    my $dest = File::Spec->catfile($artifact_dir, 'cpanm_work_build.log');

    if (!copy($source, $dest)) {
        open my $efh, '>>', $artifact_err;
        print {$efh} "copy $source to $dest failed: $!\n" if $efh;
        close $efh if $efh;
    }
}

sub _find_in_path {
    my ($name) = @_;

    for my $dir (File::Spec->path) {
        my $path = File::Spec->catfile($dir, $name);
        return $path if -f $path && -x $path;
    }

    return;
}

sub _truncate_file {
    my ($path) = @_;
    open my $fh, '>', $path or die "cannot write $path: $!\n";
    close $fh or die "cannot close $path: $!\n";
}

sub _cwd {
    require Cwd;
    return Cwd::getcwd();
}

sub _normalize_wait_status {
    my ($status) = @_;

    return 255 if !defined $status || $status == -1;

    my $signal = $status & 127;
    return 128 + $signal if $signal;

    return $status >> 8;
}

1;
