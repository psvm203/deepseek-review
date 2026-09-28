#!/usr/bin/env nu
# Author: hustcer
# Created: 2025/04/02 20:02:15
# Description: Diff command for DeepSeek-Review

use common.nu [GITHUB_API_BASE, ECODE, git-check, has-ref]
use util.nu [glob-to-regex, generate-include-regex, generate-exclude-regex, prepare-awk, is-safe-git]

# If the PR title or body contains any of these keywords, skip the review
const IGNORE_REVIEW_KEYWORDS = ['skip review' 'skip cr']

# Get the diff content from GitHub PR or local git changes and apply filters
export def get-diff [
  --repo: string,       # GitHub repository name
  --pr-number: string,  # GitHub PR number
  --diff-to: string,    # Diff to git ref
  --diff-from: string,  # Diff from git ref
  --include: string,    # Comma separated file patterns to include in the code review
  --exclude: string,    # Comma separated file patterns to exclude in the code review
  --patch-cmd: string,  # The `git show` or `git diff` command to get the diff content
  --patch-file: string,  # Location of the patch file to review
] {
  let content = (
    get-diff-content --repo $repo --pr-number $pr_number --patch-cmd $patch_cmd
      --diff-to $diff_to --diff-from $diff_from --include $include --exclude $exclude
      --patch-file $patch_file)
  let content = apply-file-filters $content --include $include --exclude $exclude

  if ($content | is-empty) {
    print $'(ansi g)Nothing to review.(ansi reset)'
    exit $ECODE.SUCCESS
  }

  $content
}

# Get diff content from GitHub PR or local git changes
def get-diff-content [
  --repo: string,       # GitHub repository name
  --pr-number: string,  # GitHub PR number
  --diff-to: string,    # Diff to git ref
  --diff-from: string,  # Diff from git ref
  --include: string,    # Comma separated file patterns to include in the code review
  --exclude: string,    # Comma separated file patterns to exclude in the code review
  --patch-cmd: string,  # The `git show` or `git diff` command to get the diff content
  --patch-file: string,  # Location of the patch file to review
] {
  let local_repo = $env.PWD

  if ($pr_number | is-not-empty) {
    get-pr-diff --repo $repo $pr_number --include $include --exclude $exclude
  } else if ($diff_from | is-not-empty) {
    get-ref-diff $diff_from --diff-to $diff_to
  } else if ($patch_file | is-not-empty) {
    if not ($patch_file | path exists) {
      print $'(ansi r)The patch file ($patch_file) does not exist, bye...(ansi reset)(char nl)'
      exit $ECODE.INVALID_PARAMETER
    }
    # `path exists` is also true for a directory, and `open --raw` on one throws a
    # raw IO error instead of our message. `path expand` resolves symlinks first,
    # so a symlinked patch file still reads as `file`.
    if ($patch_file | path expand | path type) != 'file' {
      print $'(ansi r)The patch file ($patch_file) is not a regular file, bye...(ansi reset)(char nl)'
      exit $ECODE.INVALID_PARAMETER
    }
    open --raw $patch_file
  } else if not (git-check $local_repo --check-repo=1) {
    print $'Current directory ($local_repo) is (ansi r)NOT(ansi reset) a git repo, bye...(char nl)'
    exit $ECODE.CONDITION_NOT_SATISFIED
  } else if ($patch_cmd | is-not-empty) {
    get-patch-diff $patch_cmd
  } else {
    git diff
  }
}

# Get the diff content of the specified GitHub PR,
# if the PR description contains the skip keyword, exit
def get-pr-diff [
  --repo: string,       # GitHub repository name
  pr_number: string,    # GitHub PR number
  --include: string,
  --exclude: string,
] {
  let BASE_HEADER = [Authorization $'Bearer ($env.GH_TOKEN)' Accept application/vnd.github.v3+json]
  let DIFF_HEADER = [Authorization $'Bearer ($env.GH_TOKEN)' Accept application/vnd.github.v3.diff]

  if ($repo | is-empty) {
    print $'(ansi r)Please provide the GitHub repository name by `--repo` option.(ansi reset)'
    exit $ECODE.INVALID_PARAMETER
  }

  let pr = http get -H $BASE_HEADER $'($GITHUB_API_BASE)/repos/($repo)/pulls/($pr_number)'
  let description = $pr | select title body | values | str join "\n"

  # Check if the PR title or body contains keywords to skip the review
  if ($IGNORE_REVIEW_KEYWORDS | any {|it| $description =~ $it }) {
    print $'(ansi r)The PR title or body contains keywords to skip the review, bye...(ansi reset)'
    exit $ECODE.SUCCESS
  }

  let commit_msg = http get -H $BASE_HEADER $'($GITHUB_API_BASE)/repos/($repo)/pulls/($pr_number)/commits'
                   | last | get commit.message
  if ($IGNORE_REVIEW_KEYWORDS | any {|it| $commit_msg =~ $it }) {
    print $'(ansi r)The latest PR commit message contains keywords to skip the review, bye...(ansi reset)'
    exit $ECODE.SUCCESS
  }

  # Filtering a downloaded patch is too late when GitHub cannot render the PR.
  # The files API is also capped at 3,000 files, so use Git for large PRs.
  if ($pr.changed_files? | default 0) >= 3000 {
    return (get-pr-git-diff $pr --include $include --exclude $exclude)
  }
  try {
    http get -H $DIFF_HEADER $'($GITHUB_API_BASE)/repos/($repo)/pulls/($pr_number)' | str trim
  } catch {
    get-pr-git-diff $pr --include $include --exclude $exclude
  }
}

# Generate the same three-dot comparison as a PR without GitHub's diff limits.
# A temporary bare repository also works without checkout, on forks, and from a
# shallow/unrelated working tree. Never check out or execute code from the PR.
def get-pr-git-diff [pr: record, --include: string, --exclude: string] {
  print -e 'Generating PR diff with Git to avoid GitHub diff limits...'
  let dir = mktemp -d -t 'deepseek-review-XXXXXX'
  # Pass credentials through the environment, not arguments or on-disk config.
  $env.DEEPSEEK_GIT_AUTH = $'AUTHORIZATION: basic ($'x-access-token:($env.GH_TOKEN)' | encode base64)'
  $env.GIT_TERMINAL_PROMPT = '0'
  let git = {|...args|
    let result = (^git --config-env=http.https://github.com/.extraheader=DEEPSEEK_GIT_AUTH
      -C $dir ...$args | complete)
    if $result.exit_code != 0 {
      error make { msg: $'Could not generate PR diff with Git: ($result.stderr | str trim)' }
    }
    $result.stdout
  }
  let content = try {
    do $git ...[init --bare --quiet] | ignore
    do $git remote add origin $pr.base.repo.clone_url | ignore
    # Fetch the exact commits, including the fork's head through the base repo.
    # Full commit history is needed to find the true merge base.
    do $git config remote.origin.promisor true | ignore
    do $git config remote.origin.partialclonefilter blob:none | ignore
    do $git ...[fetch --quiet --no-tags --filter=blob:none origin $pr.base.sha $pr.head.sha] | ignore
    let range = $'($pr.base.sha)...($pr.head.sha)'
    # List paths without reading blobs, then fetch content only for matching files.
    # Disable rename detection so it cannot download unrelated blobs to compare.
    mut paths = do $git ...[diff --name-only --no-renames -z $range --]
      | split row (char nul) | where $it != ''
    if ($include | is-not-empty) {
      let pattern = $'^(glob-to-regex ($include | split row ","))$'
      $paths = $paths | where {|path| $path =~ $pattern }
    }
    if ($exclude | is-not-empty) {
      let pattern = $'^(glob-to-regex ($exclude | split row ","))$'
      $paths = $paths | where {|path| $path !~ $pattern }
    }
    # Bound command-line size; literal pathspecs keep filenames from becoming globs.
    $paths | chunks 100 | each {|batch|
      do $git ...[-c core.quotePath=false diff --no-ext-diff --no-textconv --no-color
        --no-renames --src-prefix=a/ --dst-prefix=b/ $range --
        ...($batch | each {|path| ':(literal)' + $path })]
    } | str join
  } catch {|err|
    rm -rf $dir
    error make $err
  }
  rm -rf $dir
  $content
}

# Get diff content from local git changes
def get-ref-diff [
  diff_from: string,    # Diff from git REF
  --diff-to: string,    # Diff to git ref
] {
  # Validate the git refs
  if not (has-ref $diff_from) {
    print $'(ansi r)The specified git ref ($diff_from) does not exist, please check it again.(ansi reset)'
    exit $ECODE.INVALID_PARAMETER
  }

  if ($diff_to | is-not-empty) and not (has-ref $diff_to) {
    print $'(ansi r)The specified git ref ($diff_to) does not exist, please check it again.(ansi reset)'
    exit $ECODE.INVALID_PARAMETER
  }

  git diff $diff_from ($diff_to | default HEAD)
}

# Get the diff content from the specified git command
def get-patch-diff [
  cmd: string  # The `git show` or `git diff` command to get the diff content
] {
  let valid = is-safe-git $cmd
  if not $valid {
    exit $ECODE.INVALID_PARAMETER
  }

  # Run the validated command with separated arguments instead of `nu -c $cmd`,
  # so the string is never re-interpreted by a shell/nu (no newline injection).
  # `is-safe-git` guarantees a simple `git show`/`git diff` whose tokens contain
  # no spaces, quotes, metacharacters, or control characters, so splitting on
  # spaces is safe here. Pathspecs like `nu/*` / `:!nu/*` reach git verbatim.
  let argv = $cmd | str trim | split row -r ' +'
  ^($argv | first) ...($argv | skip 1)
}

# Apply file filters to the diff content to include or exclude specific files
def apply-file-filters [
  content: string,      # The diff content to filter
  --include: string,    # Comma separated file patterns to include in the code review
  --exclude: string,    # Comma separated file patterns to exclude in the code review
] {
  if ($content | is-empty) { return '' }
  mut filtered_content = $content
  let awk_bin = (prepare-awk)

  if ($include | is-not-empty) {
    let patterns = $include | split row ','
    $filtered_content = run-awk-filter $awk_bin (generate-include-regex $patterns) $filtered_content
  }

  if ($exclude | is-not-empty) {
    let patterns = $exclude | split row ','
    $filtered_content = run-awk-filter $awk_bin (generate-exclude-regex $patterns) $filtered_content
  }

  $filtered_content
}

# Drain both output streams before try waits for the external command to finish.
# Keep the historical filter failure status (1), with the actual cause on stderr.
def run-awk-filter [awk_bin: string, program: string, content: string] {
  let result = try {
    $content | ^$awk_bin $program | complete
  } catch {|err|
    print -e $'Could not run diff filter with ($awk_bin): ($err.msg)'
    exit $ECODE.OUTDATED
  }
  if $result.exit_code != 0 {
    print -e $'Diff filter failed with ($awk_bin) with exit code ($result.exit_code): ($result.stderr)'
    exit $ECODE.OUTDATED
  }
  if ($result.stderr | is-not-empty) {
    print -en $result.stderr
  }
  # External output assigned to a Nu string previously lost one terminal newline.
  # Match that conversion exactly; never trim meaningful spaces or blank lines.
  $result.stdout | str replace -r '\r?\n$' ''
}
