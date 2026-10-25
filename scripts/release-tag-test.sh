#!/usr/bin/env bash
# Isolated Git fixtures exercise the CLI without touching repository tags or origin.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$root/temp-data"
fixture=$(mktemp -d "$root/temp-data/release-tag-test.XXXXXX")
trap 'rm -rf "$fixture"' EXIT
cat > "$fixture/git" <<'MOCK'
#!/usr/bin/env bash
case "$*" in
  'tag --list v*') printf '%s\n' "${TEST_LOCAL_TAGS:-}" ;;
  'ls-remote --tags origin')
    [[ ${TEST_REMOTE_FAIL:-0} == 0 ]] || exit 1
    while IFS= read -r tag; do
      [[ -z $tag ]] || printf '0123456789abcdef\trefs/tags/%s\n' "$tag"
    done <<< "${TEST_REMOTE_TAGS:-}"
    ;;
  'tag v'*) printf '%s\n' "$2" >> "${TEST_CREATED_TAGS:?}" ;;
  *) printf 'Unexpected Git operation: %s\n' "$*" >&2; exit 90 ;;
esac
MOCK
chmod +x "$fixture/git"
export PATH="$fixture:$PATH"
unset GITHUB_ACTIONS GITHUB_REF
export TEST_LOCAL_TAGS='v2026.10.8-r1'
export TEST_REMOTE_TAGS='v2026.10.8-r3'
case_count=0
run_case() {
  local name=$1 expected=$2 reason=$3 output status=0
  shift 3
  output=$(bash "$root/scripts/release-tag.sh" "$@" 2>&1) || status=$?
  printf '%s | expected=%s actual=%s | %s\n' "$name" "$expected" "$status" "$output"
  [[ $status == "$expected" && $output == *"$reason"* ]] || exit 1
  case_count=$((case_count + 1))
}
run_case 'invalid shape' 1 'Invalid tag' --check '2026.10.8-r4'
run_case 'revision zero' 1 'Invalid tag' --check 'v2026.10.8-r0'
run_case 'revision overflow' 1 'Invalid tag' --check 'v2026.10.8-r1000'
run_case 'used revision (remote)' 1 'Tag already used' --check 'v2026.10.8-r3'
run_case 'older date' 1 'earlier than' --check 'v2026.10.7-r4'
# 跨月比较必须按数字：'2026.9.30' 按字典序大于 '2026.10.8'，字典序实现会放行它。
run_case 'earlier month, larger digit' 1 'earlier than' --check 'v2026.9.30-r1'
run_case 'dry tag' 0 'Valid tag' --check 'v2026.10.8-r1-dry.2'
run_case 'same-day gap' 1 'must increase' --check 'v2026.10.8-r2'
# 平年 2 月只有 28 天，2023.2.29 必须拒；下面 2024.2.29 合法，两条配成一闰一平的对子。
run_case 'non-leap Feb 29 rejected' 1 'Invalid tag' --check 'v2023.2.29-r1'
# 下面三条只考察 tag 自身的格式与日历边界，清空既有 tag，免得时序校验把日期较早的用例提前拦掉。
export TEST_LOCAL_TAGS='' TEST_REMOTE_TAGS=''
run_case 'leap day accepted' 0 'Valid tag' --check 'v2024.2.29-r1'
# 月份上限必须拒：13 月的日期数字比 10 月大，不设上限会被数字排序碰巧放行。
run_case 'month overflow rejected' 1 'Invalid tag' --check 'v2026.13.1-r1'
# 干跑序号从 1 起（fleet-doc/git.md），-dry.0 非法。
run_case 'dry revision zero rejected' 1 'Invalid tag' --check 'v2026.10.8-r1-dry.0'
export TEST_LOCAL_TAGS='v2026.10.8-r1' TEST_REMOTE_TAGS='v2026.10.8-r3'
run_case 'leading zero' 1 'Invalid tag' --check 'v2026.10.08-r4'
run_case 'numeric month ordering' 0 'Valid tag' --check 'v2026.11.1-r1'
export TEST_REMOTE_TAGS=$'v2026.10.8-r3\nv2026.10.8-r1-dry.2\nv2099.1.1-r1-dry.1'
run_case 'repeated dry tag' 1 'Tag already used' --check 'v2026.10.8-r1-dry.2'
run_case 'future dry ignored' 0 'Valid tag' --check 'v2026.10.8-r4'
export GITHUB_ACTIONS=true GITHUB_REF=refs/tags/v2026.10.8-r3
run_case 'workflow current tag excluded' 0 'Valid tag' --check 'v2026.10.8-r3'
export GITHUB_REF=refs/tags/v2026.10.8-r4
run_case 'workflow other tag not excluded' 1 'Tag already used' --check 'v2026.10.8-r3'
unset GITHUB_ACTIONS GITHUB_REF
export TEST_REMOTE_FAIL=1
run_case 'remote failure closed' 1 'Cannot read origin' --check 'v2026.10.8-r4'
unset TEST_REMOTE_FAIL
now=$(TZ=Asia/Shanghai date +'%Y.%-m.%-d')
# 干跑分配只看正式 tag：远端有更高序号的干跑 tag（r9-dry.9 的 N 远大于 9）也要忽略，否则会分配出 r10 而不是 r3。
export TEST_LOCAL_TAGS="v$now-r2" TEST_REMOTE_TAGS="v$now-r2
v$now-r9-dry.9"
run_case 'higher dry tag ignored when allocating' 0 "Git tag: v$now-r3" --dry
export TEST_LOCAL_TAGS="v$now-r2" TEST_REMOTE_TAGS="v$now-r9"
run_case 'dry allocation from remote maximum' 0 "Git tag: v$now-r10" --dry
export TEST_REMOTE_TAGS="v$now-r999"
run_case 'daily exhaustion' 1 'exhausted' --dry

# 默认模式只在本地打当天的下一个 tag，不读也不改 overlays/prod（版本由 CI 构建完镜像后回写）。
# 在一个没有 deploy/ 目录的临时目录里跑，证明它不依赖覆盖层。
export TEST_CREATED_TAGS="$fixture/created-tags"
: > "$TEST_CREATED_TAGS"
export TEST_LOCAL_TAGS="v$now-r2" TEST_REMOTE_TAGS="v$now-r2"
mkdir -p "$fixture/repo"
cd "$fixture/repo"
run_case 'create tags next revision without an overlay' 0 "Git tag: v$now-r3"
[[ $(cat "$TEST_CREATED_TAGS") == "v$now-r3" ]] || { echo "create did not tag v$now-r3"; exit 1; }
run_case 'prepare mode removed' 1 'Usage: release-tag.sh [--dry | --check <tag>]' --prepare
cd "$root"
printf 'All %s cases passed.\n' "$case_count"
