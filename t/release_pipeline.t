#!/usr/bin/env perl
use strict;
use warnings;

use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

sub write_file {
    my ($path, $text, $mode) = @_;
    my (undef, $dir) = File::Spec->splitpath($path);
    make_path($dir) if $dir && !-d $dir;
    open my $fh, '>', $path or die "write $path: $!";
    print {$fh} $text;
    close $fh or die "close $path: $!";
    chmod($mode, $path) if defined $mode;
}

sub run_capture {
    my ($command) = @_;
    my $output = `$command 2>&1`;
    return ($? >> 8, $output);
}

my $root = tempdir(CLEANUP => 1);
my $repo = File::Spec->catdir($root, 'repository');
my $dist = File::Spec->catdir($root, 'distribution');
my $dev  = File::Spec->catdir($root, 'development');
make_path($repo, $dev);

write_file(File::Spec->catfile($repo, 'tracked.txt'), "tracked\n");
write_file(
    File::Spec->catfile($repo, '.gitattributes'),
    "/.gitattributes export-ignore\n"
        . "/AGENTS.md export-ignore\n"
        . "/LLM export-ignore\n"
        . "/docs/ChatGPT-review.txt export-ignore\n",
);
write_file(File::Spec->catfile($repo, 'AGENTS.md'), "internal agent instructions\n");
write_file(File::Spec->catfile($repo, 'LLM', 'prompt.txt'), "internal model prompt\n");
write_file(
    File::Spec->catfile($repo, 'docs', 'ChatGPT-review.txt'),
    "internal model review\n",
);
write_file(File::Spec->catfile($repo, 'docs', 'public.md'), "public documentation\n");
system('git', '-C', $repo, 'init', '-q') == 0 or die 'git init failed';
system('git', '-C', $repo, 'add', '.') == 0 or die 'git add failed';
local $ENV{GIT_AUTHOR_NAME} = 'Smoker Test';
local $ENV{GIT_AUTHOR_EMAIL} = 'smoker-test.invalid';
local $ENV{GIT_COMMITTER_NAME} = $ENV{GIT_AUTHOR_NAME};
local $ENV{GIT_COMMITTER_EMAIL} = $ENV{GIT_AUTHOR_EMAIL};
system('git', '-C', $repo, 'commit', '-qm', 'fixture') == 0 or die 'git commit failed';
write_file(File::Spec->catfile($repo, 'untracked.txt'), "exclude me\n");

my $builder = File::Spec->rel2abs('bin/make_distribution.sh');
my ($rc, $output) = run_capture(
    "SMOKER_REPOSITORY='$repo' SMOKER_DISTRIBUTION='$dist' bash '$builder'"
);
is($rc, 0, 'distribution build succeeds');
ok(-f File::Spec->catfile($dist, 'tracked.txt'), 'tracked content is included');
ok(!-e File::Spec->catfile($dist, 'untracked.txt'), 'untracked content is excluded');
ok(-f File::Spec->catfile($dist, 'RELEASE_SOURCE.txt'), 'source manifest is generated');
ok(!-e File::Spec->catfile($dist, '.gitattributes'), 'export policy is excluded');
ok(!-e File::Spec->catfile($dist, 'AGENTS.md'), 'agent instructions are excluded');
ok(!-e File::Spec->catfile($dist, 'LLM'), 'internal model-review tree is excluded');
ok(
    !-e File::Spec->catfile($dist, 'docs', 'ChatGPT-review.txt'),
    'internal model review is excluded',
);
ok(-f File::Spec->catfile($dist, 'docs', 'public.md'), 'public documentation is included');

write_file(File::Spec->catfile($dist, 'obsolete.txt'), "old distribution content\n");
($rc, $output) = run_capture(
    "SMOKER_REPOSITORY='$repo' SMOKER_DISTRIBUTION='$dist' bash '$builder'"
);
is($rc, 0, 'atomic rebuild succeeds');
ok(!-e File::Spec->catfile($dist, 'obsolete.txt'), 'rebuild removes obsolete generated content');

($rc, $output) = run_capture(
    "SMOKER_REPOSITORY='$repo' bash '$builder' --output '$repo/distribution'"
);
isnt($rc, 0, 'builder rejects an output inside the repository');
like($output, qr/outside the repository/, 'unsafe output rejection is explicit');

my $sync = File::Spec->rel2abs('admin/sync_smoker_trees.sh');
($rc, $output) = run_capture(
    "SMOKER_ROOT='$root' SMOKER_DEVELOPMENT='$dev' "
    . "SMOKER_REPOSITORY='$repo' SMOKER_DISTRIBUTION='$dist' "
    . "bash '$sync' --dry-run --no-distribution"
);
is($rc, 0, 'sync dry-run honors explicit tree overrides');
like($output, qr/\Q$repo\E/, 'sync reports overridden repository');
like($output, qr/\Q$dist\E/, 'sync reports overridden distribution');

done_testing();
