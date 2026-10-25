#!/usr/bin/env bash
# Run from the repository root. Only the no-argument mode creates a local tag.
# --prepare writes the next image tag into the production overlay (no tag); the
# no-argument mode refuses to tag unless that overlay already pins the same tag.
set -euo pipefail
export LC_ALL=C

fail() { printf 'Error: %s\n' "$*" >&2; exit 1; }

# 生产环境部署的镜像版本以这一行为准：Argo CD 跟 release 分支，release 在 tag 推送后快进到 tag。
# 所以打 tag 之前它必须已经写好并合进 main，否则 release 指向的提交部署的是旧版本。
PROD_OVERLAY=deploy/k8s/linksail/overlays/prod/kustomization.yaml
PROD_IMAGE=hubwu42/new-api

require_overlay() {
  [[ -f $PROD_OVERLAY ]] || fail "Production overlay not found: $PROD_OVERLAY (run from the repository root)."
}

# 读出生产覆盖层里给 hubwu42/new-api 钉的 tag（找不到则输出为空）。调用前先 require_overlay。
pinned_tag() {
  awk -v img="$PROD_IMAGE" '
    $1 == "-" && $2 == "name:" { inside = ($3 == img); next }
    inside && $1 == "newTag:" { print $2; exit }
  ' "$PROD_OVERLAY"
}

write_pinned_tag() {
  local image_tag=$1 tmp
  require_overlay
  [[ -n $(pinned_tag) ]] || fail "No newTag line for $PROD_IMAGE in $PROD_OVERLAY."
  tmp=$(mktemp "${PROD_OVERLAY}.XXXXXX")
  awk -v img="$PROD_IMAGE" -v tag="$image_tag" '
    $1 == "-" && $2 == "name:" { inside = ($3 == img) }
    inside && $1 == "newTag:" { sub(/newTag:.*/, "newTag: " tag); inside = 0 }
    { print }
  ' "$PROD_OVERLAY" > "$tmp"
  mv "$tmp" "$PROD_OVERLAY"
}

# Parsed values are numeric so October sorts after September on BSD and GNU systems.
# 解析结果经 stdout 显式返回一行：`<date> <revision> <dry>`（dry 为空即正式 tag）。
parse_tag() {
  local tag=$1 year month day limit
  [[ $tag =~ ^v([0-9]{4})\.([1-9][0-9]?)\.([1-9][0-9]?)-r([1-9][0-9]{0,2})(-dry\.([1-9][0-9]*))?$ ]] || return 1
  year=$((10#${BASH_REMATCH[1]}))
  month=${BASH_REMATCH[2]}
  day=${BASH_REMATCH[3]}
  (( year > 0 && month <= 12 )) || return 1
  case $month in
    4|6|9|11) limit=30 ;;
    2)
      limit=28
      if (( year % 400 == 0 || (year % 4 == 0 && year % 100 != 0) )); then limit=29; fi
      ;;
    *) limit=31 ;;
  esac
  (( day <= limit )) || return 1
  printf '%s %s %s\n' "$((year * 10000 + month * 100 + day))" "${BASH_REMATCH[4]}" "${BASH_REMATCH[5]}"
}

load_tags() {
  local local_tags remote_tags oid ref
  local_tags=$(git tag --list 'v*') || fail 'Cannot read local tags.'
  remote_tags=$(git ls-remote --tags origin) || fail 'Cannot read origin tags; refusing to allocate or validate a release.'
  all_tags=$local_tags
  while read -r oid ref; do
    [[ $ref == refs/tags/* ]] || continue
    ref=${ref#refs/tags/}
    # Annotated tags have an additional peeled record, not a second tag.
    ref=${ref%\^\{\}}
    all_tags+=$'\n'"$ref"
  done <<< "$remote_tags"
}

# 解析失败就按同一个消息报错；成功则把 parse_tag 的输出原样传给调用方。
require_valid_tag() {
  parse_tag "$1" || fail "Invalid tag: $1 (use vYYYY.M.D-r1..999, valid date, no leading zeros; optional -dry.N with N >= 1)."
}

check_tag() {
  local candidate=$1 existing parsed candidate_date candidate_revision candidate_dry existing_date existing_revision existing_dry
  parsed=$(require_valid_tag "$candidate")
  read -r candidate_date candidate_revision candidate_dry <<< "$parsed"
  while IFS= read -r existing; do
    # GitHub validates a tag which is already present. The local CLI never excludes it.
    if [[ $existing == "$candidate" ]]; then
      if [[ ${GITHUB_ACTIONS:-} == true && ${GITHUB_REF:-} == "refs/tags/$candidate" ]]; then
        continue
      fi
      fail "Tag already used: $candidate."
    fi
    parsed=$(parse_tag "$existing") || continue
    read -r existing_date existing_revision existing_dry <<< "$parsed"
    # Dry runs have separate immutable names and do not advance production ordering.
    [[ -z $candidate_dry && -z $existing_dry ]] || continue
    (( candidate_date >= existing_date )) || fail "Release date is earlier than existing formal tag: $existing."
    if (( candidate_date == existing_date && candidate_revision <= existing_revision )); then
      fail "Same-day revision must increase beyond existing formal tag: $existing."
    fi
  done <<< "$all_tags"
}

mode=${1:-create}
case $mode in
  create) (( $# == 0 )) || fail 'Usage: release-tag.sh [--dry | --prepare | --check <tag>]' ;;
  --dry) (( $# == 1 )) || fail 'Usage: release-tag.sh --dry' ;;
  --prepare) (( $# == 1 )) || fail 'Usage: release-tag.sh --prepare' ;;
  --check) (( $# == 2 )) || fail 'Usage: release-tag.sh --check <tag>'
    require_valid_tag "$2" > /dev/null
    ;;
  *) fail 'Usage: release-tag.sh [--dry | --prepare | --check <tag>]' ;;
esac
load_tags
if [[ $mode == --check ]]; then
  check_tag "$2"
  printf 'Valid tag: %s\n' "$2"
  exit 0
fi

today=$(TZ=Asia/Shanghai date +'%Y.%-m.%-d')
today_parsed=$(parse_tag "v$today-r1") || fail 'Cannot determine the Beijing release date.'
read -r today_number _ _ <<< "$today_parsed"
revision=0
while IFS= read -r existing; do
  parsed=$(parse_tag "$existing") || continue
  read -r existing_date existing_revision existing_dry <<< "$parsed"
  [[ -z $existing_dry ]] || continue
  if (( existing_date == today_number && existing_revision > revision )); then revision=$existing_revision; fi
done <<< "$all_tags"
(( revision < 999 )) || fail "All revisions for $today are exhausted (maximum r999)."
tag="v$today-r$((revision + 1))"
check_tag "$tag"
if [[ $mode == --prepare ]]; then
  write_pinned_tag "${tag#v}"
  printf 'Pinned %s:%s in %s\nMerge this change into main, then run release-tag.sh to create %s.\n' \
    "$PROD_IMAGE" "${tag#v}" "$PROD_OVERLAY" "$tag"
  exit 0
fi
if [[ $mode == create ]]; then
  require_overlay
  pinned=$(pinned_tag)
  [[ $pinned == "${tag#v}" ]] || fail "$PROD_OVERLAY pins $PROD_IMAGE:${pinned:-<none>}, not ${tag#v}. Run release-tag.sh --prepare, merge it into main, then tag."
  git tag "$tag" || fail "Could not create local tag: $tag."
fi
printf 'Git tag: %s\nImage tag: %s\n' "$tag" "${tag#v}"
