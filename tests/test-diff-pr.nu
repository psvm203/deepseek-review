use std/assert
use std/testing *

@before-all
def setup [] {
  let source_dir = $env.PWD | path join nu
  let dir = mktemp -d -t 'dsr-pr-test-XXXXXX'
  let repo = $dir | path join repo
  mkdir $repo
  $env.GIT_CONFIG_GLOBAL = $dir | path join no-gitconfig
  $env.GIT_CONFIG_SYSTEM = $env.GIT_CONFIG_GLOBAL
  cd $repo
  git -c init.defaultBranch=main init -q
  git config user.email tests@deepseek-review.invalid
  git config user.name 'DeepSeek Review Tests'
  git config commit.gpgsign false
  git config uploadpack.allowFilter true
  git config uploadpack.allowAnySHA1InWant true
  mkdir src assets
  'class Before {}' | save Root.cs
  'class Removed {}' | save src/Removed.cs
  'class Renamed {}' | save src/Old.cs
  git add .
  git commit -qm initial
  let common = git rev-parse HEAD | str trim
  'class After {}' | save -f Root.cs
  'class Added {}' | save 'src/New file.cs'
  'class Generated {}' | save src/Generated.cs
  'class Literal {}' | save 'src/[One].cs'
  'class Other {}' | save src/O.cs
  rm src/Removed.cs
  git mv src/Old.cs src/Renamed.cs
  for i in 1..3001 { $'asset ($i)' | save ($'assets/($i).meta') }
  git add .
  git commit -qm feature
  let head = git rev-parse HEAD | str trim
  git checkout -qb base $common
  'class BaseOnly {}' | save BaseOnly.cs
  git add .
  git commit -qm 'base advanced'
  let base = git rev-parse HEAD | str trim

  # Mock only HTTP; the actual diff module fetches and compares a real Git repo.
  let modules = $dir | path join nu
  mkdir $modules
  cp ($source_dir | path join common.nu) $modules
  cp ($source_dir | path join util.nu) $modules
  let mock = r#'
def "http get" [--headers(-H): list, url: string] {
  let pr = $env.TEST_PR_JSON | from json
  if 'application/vnd.github.v3.diff' in $headers {
    'diff requested' | save -f $env.TEST_DIFF_REQUEST
    error make { msg: 'GitHub diff is too large' }
  }
  if ($url | str ends-with '/commits') {
    [{commit: {message: 'feature'}}]
  } else { $pr }
}
'#
  ((open -r ($source_dir | path join diff.nu)) + $mock)
    | save ($modules | path join diff.nu)
  {
    dir: $dir,
    modules: $modules,
    pr: {
      title: 'Large PR', body: '', changed_files: 3009,
      base: {sha: $base, repo: {clone_url: $'file:///($repo | str replace -a "\\" "/" | str replace -r "^/+" "")'}},
      head: {sha: $head}
    }
  }
}

@after-all
def teardown [] { rm -rf $in.dir }

def run-diff [ctx: record, pr: record, flags: string] {
  $env.GH_TOKEN = 'test-placeholder'
  $env.TEST_PR_JSON = $pr | to json -r
  $env.TEST_DIFF_REQUEST = $ctx.dir | path join $'request-(random chars -l 8)'
  $env.GIT_CONFIG_GLOBAL = $ctx.dir | path join no-gitconfig
  $env.GIT_CONFIG_SYSTEM = $env.GIT_CONFIG_GLOBAL
  let result = (^$nu.current-exe -n -I $ctx.modules -c $'
    use diff.nu get-diff
    get-diff --repo owner/repo --pr-number 1 ($flags)
  ' | complete)
  $result | insert requested_diff ($env.TEST_DIFF_REQUEST | path exists)
}

@test
def 'PR diff：filters over 3000 files without requesting the full diff' [] {
  let ctx = $in
  let result = run-diff $ctx $ctx.pr '--include "*.cs" --exclude "**/Generated.cs"'
  assert equal $result.exit_code 0 $result.stderr
  assert equal $result.requested_diff false
  for name in [Root.cs 'src/New file.cs' src/Removed.cs src/Old.cs src/Renamed.cs] {
    assert ($result.stdout | str contains $name) $'Missing ($name)'
  }
  assert not ($result.stdout | str contains '.meta')
  assert not ($result.stdout | str contains 'Generated.cs')
  assert not ($result.stdout | str contains 'BaseOnly.cs')
}

@test
def 'PR diff：falls back to Git when a smaller PR diff request fails' [] {
  let ctx = $in
  let result = run-diff $ctx ($ctx.pr | update changed_files 100) '--include "**/*.cs"'
  assert equal $result.exit_code 0 $result.stderr
  assert equal $result.requested_diff true
  assert ($result.stdout | str contains 'Root.cs')
  assert ($result.stdout | str contains 'src/Renamed.cs')
  assert not ($result.stdout | str contains '.meta')
}

@test
def 'PR diff：no matching files skips review successfully' [] {
  let ctx = $in
  let result = run-diff $ctx $ctx.pr '--include "*.does-not-exist"'
  assert equal $result.exit_code 0 $result.stderr
  assert ($result.stdout | str contains 'Nothing to review.')
}

@test
def 'PR diff：multiple patterns and exclude-only filters work' [] {
  let ctx = $in
  let result = run-diff $ctx $ctx.pr '--include "Root.cs,src/*" --exclude "**/Generated.cs"'
  assert equal $result.exit_code 0 $result.stderr
  assert not ($result.stdout | str contains '.meta')
  assert not ($result.stdout | str contains 'Generated.cs')
  assert ($result.stdout | str contains 'src/New file.cs')
  let excluded = run-diff $ctx $ctx.pr '--exclude "*.cs"'
  assert equal $excluded.exit_code 0 $excluded.stderr
  assert not ($excluded.stdout | str contains '.cs')
  assert equal ($excluded.stdout | lines | where $it starts-with 'diff --git ' | length) 3001
}

@test
def 'PR diff：passes filenames as literal Git pathspecs' [] {
  let ctx = $in
  let result = run-diff $ctx $ctx.pr '--include "src/[One].cs"'
  assert equal $result.exit_code 0 $result.stderr
  let headers = $result.stdout | lines | where $it starts-with 'diff --git '
  assert equal $headers ['diff --git a/src/[One].cs b/src/[One].cs']
}

@test
def 'PR diff：Git fetch failures are not treated as an empty diff' [] {
  let ctx = $in
  let result = run-diff $ctx ($ctx.pr | update head.sha ('f' | fill -w 40 -c f)) '--include "*.cs"'
  assert ($result.exit_code != 0)
  assert ($result.stderr | str contains 'Could not generate PR diff with Git')
  assert not ($result.stdout | str contains 'Nothing to review.')
}
