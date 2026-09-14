package Smoker::Docker;
use strict;
use warnings;

use Exporter 'import';
use Cwd qw(abs_path);
use Digest::SHA qw(sha1_hex);
use File::Path qw(make_path);
use File::Spec;
use POSIX qw(_exit WNOHANG);
use Time::HiRes qw(time sleep);

our @EXPORT_OK = qw(
    build_docker_cmd
    docker_cmd_string
    ensure_image
    run_logged
);

sub build_docker_cmd {
    my (%args) = @_;

    my $run_dir = $args{run_dir}
        or die "build_docker_cmd missing run_dir\n";

    my $base = $args{base}
        or die "build_docker_cmd missing base\n";

    my $module = $args{module}
        or die "build_docker_cmd missing module\n";

    my $version         = defined $args{version}         ? $args{version}         : '';
    my $mode            = defined $args{mode}            ? $args{mode}            : 'baseline';
    my $dep_one         = defined $args{dep_one}         ? $args{dep_one}         : '';
    my $dep_one_version = defined $args{dep_one_version} ? $args{dep_one_version} : '';
    my $dep_two         = defined $args{dep_two}         ? $args{dep_two}         : '';
    my $dep_two_version = defined $args{dep_two_version} ? $args{dep_two_version} : '';

    my $smoker_root = $args{smoker_root} || $ENV{SMOKER_HOME} || $ENV{SMOKER_ROOT}
        or die "build_docker_cmd missing smoker_root and SMOKER_HOME/SMOKER_ROOT not set\n";

    my $run_dir_abs = abs_path($run_dir)
        or die "build_docker_cmd could not resolve run_dir=$run_dir\n";

    my $smoker_root_abs = abs_path($smoker_root)
        or die "build_docker_cmd could not resolve smoker_root=$smoker_root\n";

    my $cache = $ENV{SMOKER_TARBALL_CACHE} // '';
    my $cache_abs = '';

    if ($cache ne '') {
        $cache_abs = abs_path($cache)
            or die "build_docker_cmd could not resolve SMOKER_TARBALL_CACHE=$cache\n";
    }

    my $local_mirror = $ENV{SMOKER_LOCAL_MIRROR} // '';
    my $local_mirror_abs = '';

    if ($local_mirror ne '') {
        $local_mirror_abs = abs_path($local_mirror)
            or die "build_docker_cmd could not resolve SMOKER_LOCAL_MIRROR=$local_mirror\n";
    }

    my $image = ensure_image(
        base        => $base,
        smoker_root => $smoker_root_abs,
    );

    my $uid = $<;
    my ($gid) = split /\s+/, $(;

    my @cmd = (
        'docker', 'run', '--rm',
        '--name', _container_name($run_dir_abs),

        # Run the container as the host user so files written into
        # mounted result directories are not owned by root.
        '--user', "$uid:$gid",

        '-v', "$run_dir_abs:/work/run",
        '-v', "$smoker_root_abs:/work/smoker:ro",

        '-e', "SMOKER_HOME=/work/smoker",
        '-e', "SMOKER_ROOT=/work/smoker",

        # A numeric Docker user may not have a passwd entry or home
        # directory inside the container.  Give tools a writable HOME.
        '-e', "HOME=/tmp",
        '-e', "USER=smoker",

        '-e', "SMOKER_RUN_DIR=/work/run",
        '-e', "SMOKER_MODULE=$module",
        '-e', "SMOKER_VERSION=$version",
        '-e', "SMOKER_MODE=$mode",
        '-e', "SMOKER_DEP_ONE=$dep_one",
        '-e', "SMOKER_DEP_ONE_VERSION=$dep_one_version",
        '-e', "SMOKER_DEP_TWO=$dep_two",
        '-e', "SMOKER_DEP_TWO_VERSION=$dep_two_version",
    );

    if (defined $ENV{SMOKER_TRACE_VERSION} && $ENV{SMOKER_TRACE_VERSION} ne '') {
        push @cmd, '-e', "SMOKER_TRACE_VERSION=$ENV{SMOKER_TRACE_VERSION}";
    }

    if ($cache_abs) {
        push @cmd, '-e', "SMOKER_TARBALL_CACHE=$cache_abs";
    }

    if ($local_mirror_abs) {
        push @cmd, '-e', "SMOKER_LOCAL_MIRROR=$local_mirror_abs";
    }

# Same host directory is being used as both mirror and tarball cache.
# Mount it once, read-write, to avoid Docker duplicate-mount failures.

    if ($cache_abs && $local_mirror_abs && $cache_abs eq $local_mirror_abs) {
        push @cmd, '-v', "$cache_abs:$cache_abs";
    }
    else {
        if ($cache_abs) {
            push @cmd, '-v', "$cache_abs:$cache_abs";
        }

        if ($local_mirror_abs) {
            push @cmd, '-v', "$local_mirror_abs:$local_mirror_abs:ro";
        }
    }

    push @cmd,
        '-w', '/work/run',
        $image,
        'perl',
        '-I/work/smoker/lib',
        '-MSmoker::Inner',
        '-e',
        'exit Smoker::Inner::run_from_env()';

    return @cmd;
}

sub docker_cmd_string {
    return join ' ', map { _shell_quote($_) } @_;
}

sub ensure_image {
    my (%args) = @_;

    my $base = $args{base}
        or die "ensure_image missing base\n";

    my $smoker_root = $args{smoker_root} || $ENV{SMOKER_HOME} || $ENV{SMOKER_ROOT}
        or die "ensure_image missing smoker_root and SMOKER_HOME/SMOKER_ROOT not set\n";

    my $state_dir = File::Spec->catdir($smoker_root, 'state', 'docker_images');
    make_path($state_dir);

    my $dockerfile = _dockerfile_text($base);
    my $fp = sha1_hex($dockerfile);
    my $tag = "smoker-inner:$fp";

    return $tag if _docker_image_exists($tag);

    my $build_dir = File::Spec->catdir($state_dir, $fp);
    make_path($build_dir);

    my $dockerfile_path = File::Spec->catfile($build_dir, 'Dockerfile');

    open my $dfh, '>', $dockerfile_path
        or die "write $dockerfile_path: $!";

    print {$dfh} $dockerfile;

    close $dfh
        or die "close $dockerfile_path: $!";

    my @cmd = (
        'docker', 'build',
        '-t', $tag,
        '-f', $dockerfile_path,
        $build_dir,
    );

    my $raw_rc = system(@cmd);
    my $rc     = _normalize_system_rc($raw_rc);

    die "docker build failed for $tag rc=$rc raw_rc=$raw_rc\n" if $rc != 0;

    return $tag;
}

sub _docker_image_exists {
    my ($tag) = @_;

    open my $saved_stdout, '>&', \*STDOUT
        or die "dup STDOUT before docker inspect: $!\n";
    open my $saved_stderr, '>&', \*STDERR
        or die "dup STDERR before docker inspect: $!\n";

    open STDOUT, '>', File::Spec->devnull
        or die "redirect STDOUT for docker inspect: $!\n";
    open STDERR, '>', File::Spec->devnull
        or die "redirect STDERR for docker inspect: $!\n";

    my @cmd = (
        'docker',
        'image',
        'inspect',
        $tag,
    );

    my $raw_rc = system(@cmd);

    open STDOUT, '>&', $saved_stdout
        or die "restore STDOUT after docker inspect: $!\n";
    open STDERR, '>&', $saved_stderr
        or die "restore STDERR after docker inspect: $!\n";

    my $rc = _normalize_system_rc($raw_rc);

    return $rc == 0;
}

sub _dockerfile_text {
    my ($base) = @_;

    return <<"DOCKER";
FROM $base

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \\
 && apt-get install -y --no-install-recommends \\
      ca-certificates \\
      curl \\
      make \\
      gcc \\
      g++ \\
      libc6-dev \\
      patch \\
      tar \\
      gzip \\
      bzip2 \\
      xz-utils \\
      unzip \\
      perl \\
      cpanminus \\
 && rm -rf /var/lib/apt/lists/*

WORKDIR /work/run
DOCKER
}

sub _shell_quote {
    my ($s) = @_;

    $s = '' unless defined $s;
    $s =~ s/'/'"'"'/g;

    return "'$s'";
}

sub _normalize_system_rc {
    my ($raw_rc) = @_;

    return 255 if !defined $raw_rc;
    return 255 if $raw_rc == -1;

    my $signal = $raw_rc & 127;
    return 128 + $signal if $signal;

    return $raw_rc >> 8;
}

sub run_logged {
    my ($cmd_ref, $out_path, $err_path, $timeout) = @_;

    $timeout = 1800 unless defined $timeout && $timeout =~ /\A\d+\z/ && $timeout > 0;

    open my $out, '>>', $out_path
        or die "cannot open log $out_path: $!";
    print {$out} "\n[host] running: ", docker_cmd_string(@$cmd_ref), "\n";
    close $out or die "cannot close log $out_path: $!";

    my $container_name = _container_name_from_cmd($cmd_ref);
    my $pid = fork();
    die "fork for docker run failed: $!" unless defined $pid;

    if ($pid == 0) {
        setpgrp(0, 0);
        open STDOUT, '>>', $out_path or _exit(255);
        open STDERR, '>>', $err_path or _exit(255);
        exec { $cmd_ref->[0] } @$cmd_ref or _exit(255);
    }

    my $deadline = time() + $timeout;
    my $timed_out = 0;
    my $interrupted = 0;
    my $signal = '';

    local $SIG{INT} = sub { $interrupted = 1; $signal = 'INT'; };
    local $SIG{TERM} = sub { $interrupted = 1; $signal = 'TERM'; };

    while (1) {
        my $done = waitpid($pid, WNOHANG);
        last if $done == $pid;

        if ($interrupted || time() >= $deadline) {
            $timed_out = !$interrupted;
            my $terminated_status = _terminate_process_group($pid);
            _remove_container($container_name);
            $? = $terminated_status;
            last;
        }

        sleep 0.2;
    }

    my $raw_rc = $?;
    my $rc = $timed_out ? 124
           : $interrupted ? 128 + ($signal eq 'INT' ? 2 : 15)
           : _normalize_system_rc($raw_rc);

    open $out, '>>', $out_path
        or die "cannot reopen log $out_path: $!";
    print {$out} "[host] docker rc=$rc raw_rc=$raw_rc\n";
    print {$out} "[host] timeout after ${timeout}s\n" if $timed_out;
    print {$out} "[host] interrupted by SIG$signal\n" if $interrupted;
    close $out or warn "cannot close log $out_path: $!";

    return {
        rc              => $rc,
        timed_out       => $timed_out ? 1 : 0,
        interrupted     => $interrupted ? 1 : 0,
        interrupt_signal => $signal,
        raw_wait_status => $raw_rc,
    };
}

sub _container_name {
    my ($run_dir) = @_;
    return 'smoker-' . substr(sha1_hex($run_dir), 0, 20);
}

sub _container_name_from_cmd {
    my ($cmd_ref) = @_;
    for (my $i = 0; $i < @$cmd_ref - 1; $i++) {
        return $cmd_ref->[$i + 1] if $cmd_ref->[$i] eq '--name';
    }
    return '';
}

sub _terminate_process_group {
    my ($pid) = @_;
    kill 'TERM', -$pid;
    for (1 .. 25) {
        if (waitpid($pid, WNOHANG) == $pid) {
            return $?;
        }
        sleep 0.2;
    }
    kill 'KILL', -$pid;
    waitpid($pid, 0);
    return $?;
}

sub _remove_container {
    my ($name) = @_;
    return unless defined $name && $name ne '';

    my $pid = fork();
    return unless defined $pid;
    if ($pid == 0) {
        open STDOUT, '>', File::Spec->devnull or _exit(255);
        open STDERR, '>', File::Spec->devnull or _exit(255);
        exec 'docker', 'rm', '-f', $name or _exit(255);
    }
    waitpid($pid, 0);
}

1;
