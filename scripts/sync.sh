#!/usr/bin/env bash
#
# Mirror a terraform-aws-github-runner release as Pulumi SDKs.
#
# Resolves the target upstream version, regenerates every language SDK from the
# bridged Terraform module, then commits and tags the result as v<version>.
#
# Exit codes:
#   0  synced, or already up to date (nothing to do)
#   1  hard failure
#  75  upstream release exists but is not yet resolvable from the OpenTofu
#      registry; safe to retry later (EX_TEMPFAIL)

set -euo pipefail

UPSTREAM_REPO="github-aws-runners/terraform-aws-github-runner"
# The root module provisions a single runner configuration. multi-runner wraps
# it in a map, so it covers one pool as well as several, and is the only one of
# the two worth publishing.
TF_MODULE="github-aws-runners/github-runner/aws//modules/multi-runner"
PACKAGE="github-runner"
EX_TEMPFAIL=75

# The module provider shells out to `terraform` unless told otherwise, and
# downloads its own OpenTofu when asked for it, so this spares every machine
# that runs the sync from installing either.
export PULUMI_TERRAFORM_MODULE_EXECUTOR=opentofu

# What the bridge stamps into the generated Go SDK, and what it has to become
# for `go get` to resolve it here. The Go module lives in sdks/go, so its path
# is this repository's plus that directory, and its version tags carry the same
# directory prefix (see GO_TAG_PREFIX below). Both paths gain a /vN suffix from
# v2 on, which is resolved once the version is known.
GO_MODULE_CANONICAL_BASE="github.com/pulumi/pulumi-terraform-module/sdks/go/$PACKAGE"
GO_MODULE_PATH_BASE="github.com/gvtlabs/pulumi-aws-github-runner/sdks/go"
GO_TAG_PREFIX="sdks/go/"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

version=""
force=false
do_commit=true

usage() {
  cat <<'EOF'
Usage: scripts/sync.sh [--version X.Y.Z] [--force] [--no-commit]

  --version X.Y.Z  Sync a specific upstream version instead of the latest
                   release. Useful for backfilling.
  --force          Regenerate even if the matching tag already exists. The
                   existing tag is left alone; only the working tree changes.
  --no-commit      Regenerate the SDKs but leave the result uncommitted.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version) version="${2:-}"; shift 2 ;;
    --force) force=true; shift ;;
    --no-commit) do_commit=false; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 1 ;;
  esac
done

log() { echo "==> $*"; }

# Writes a key=value pair to the workflow's step output when running in Actions.
emit() {
  [[ -n "${GITHUB_OUTPUT:-}" ]] && echo "$1=$2" >>"$GITHUB_OUTPUT"
  return 0
}

for tool in pulumi git curl python3; do
  command -v "$tool" >/dev/null || { echo "required tool not found: $tool" >&2; exit 1; }
done

if [[ -z "$version" ]]; then
  log "Looking up the latest $UPSTREAM_REPO release"
  auth=()
  [[ -n "${GH_TOKEN:-}" ]] && auth=(-H "Authorization: Bearer $GH_TOKEN")
  # bash 3.2 treats "${auth[@]}" as unbound when the array is empty.
  release="$(curl -fsSL ${auth[@]+"${auth[@]}"} \
    -H 'Accept: application/vnd.github+json' \
    "https://api.github.com/repos/$UPSTREAM_REPO/releases/latest")" || {
    echo "could not query the GitHub API for $UPSTREAM_REPO releases" >&2
    exit 1
  }
  version="$(printf '%s' "$release" |
    python3 -c 'import json,sys; print(json.load(sys.stdin)["tag_name"])')"
fi

version="${version#v}"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]] || {
  echo "not a valid upstream version: $version" >&2
  exit 1
}
tag="v$version"
go_tag="${GO_TAG_PREFIX}${tag}"
emit version "$version"
log "Upstream release is $tag"

# Go requires a module at major version 2 or above to carry that major as a
# path suffix, so an upstream major bump moves the Go SDK to a new import path.
major="${version%%.*}"
go_suffix=""
if (( major >= 2 )); then
  go_suffix="/v$major"
fi
GO_MODULE_CANONICAL="${GO_MODULE_CANONICAL_BASE}${go_suffix}"
GO_MODULE_PATH="${GO_MODULE_PATH_BASE}${go_suffix}"

tag_exists() {
  if git remote get-url origin >/dev/null 2>&1 &&
     git ls-remote --exit-code --tags origin "refs/tags/$1" >/dev/null 2>&1; then
    return 0
  fi
  git rev-parse -q --verify "refs/tags/$1" >/dev/null 2>&1
}

# It takes both tags to make a release (see the tagging loop at the bottom), so
# the guard has to ask about both. A repository carrying only the plain tag
# looks synced from the outside while the Go module has no resolvable version
# whatsoever. Regenerating would not repair that: the SDKs are already
# committed, so the run would find them byte-identical and tag HEAD, leaving
# the two tags on different commits. Restore the missing tag from the commit
# the plain one already names instead.
if tag_exists "$tag" && [[ "$force" != true ]]; then
  if tag_exists "$go_tag"; then
    log "$tag already exists, nothing to do"
    emit synced false
    exit 0
  fi

  log "$tag exists but $go_tag does not; restoring the Go module tag"
  git rev-parse -q --verify "refs/tags/$tag" >/dev/null 2>&1 ||
    git fetch --quiet origin "refs/tags/$tag:refs/tags/$tag"
  git tag -a "$go_tag" "$tag^{}" -m "terraform-aws-github-runner $tag"
  log "Tagged $go_tag at $(git rev-parse --short "$tag^{}")"
  emit synced true
  exit 0
fi

# Generate into a scratch directory so a mid-flight failure can never leave a
# half-written sdks/ behind.
staging="$(mktemp -d)"
trap 'rm -rf "$staging"' EXIT

log "Generating SDKs for $TF_MODULE $version"
if ! pulumi package gen-sdk terraform-module \
      --language all \
      --out "$staging" \
      -- "$TF_MODULE" "$version" "$PACKAGE" 2>"$staging/gen.log"; then
  cat "$staging/gen.log" >&2
  if grep -q 'Unresolvable module version constraint' "$staging/gen.log"; then
    log "$version is not on registry.opentofu.org yet; will retry on the next run"
    emit synced false
    exit "$EX_TEMPFAIL"
  fi
  exit 1
fi
grep -v 'deprecated, use' "$staging/gen.log" >&2 || true

# The bridge resolves the module from the registry; make sure it really gave us
# the release and the module we asked for rather than silently falling back.
plugin_json="$staging/python/pulumi_github_runner/pulumi-plugin.json"
[[ -f "$plugin_json" ]] || { echo "codegen produced no $plugin_json" >&2; exit 1; }
python3 - "$plugin_json" "$TF_MODULE" "$version" <<'PY'
import base64, json, sys
path, module, version = sys.argv[1:]
param = json.load(open(path))["parameterization"]
value = json.loads(base64.b64decode(param["value"]))
for what, want, got in (("version", version, param["version"]), ("module", module, value["module"])):
    if got != want:
        sys.exit(f"asked for {what} {want} but the generated SDK reports {got}")
PY

log "Replacing sdks/"
rm -rf sdks
mkdir -p sdks
for lang in python nodejs go dotnet java; do
  [[ -d "$staging/$lang" ]] || { echo "codegen produced no $lang SDK" >&2; exit 1; }
  mv "$staging/$lang" "sdks/$lang"
done
echo "$version" >UPSTREAM_VERSION

# The bridge stamps every Go SDK it generates with Pulumi's canonical module
# path, which does not match where this one lives, so `go get` cannot resolve
# it. Rewriting it to this repository's path is what makes the Go SDK a real,
# consumable module rather than something a consumer has to vendor behind a
# `replace`. The substitution is exact and total: GO_MODULE_CANONICAL is the
# module path, so every self-import below it is rewritten by the same edit.
generated_module="$(sed -n 's/^module //p' sdks/go/go.mod)"
[[ "$generated_module" == "$GO_MODULE_CANONICAL" ]] || {
  echo "expected the Go SDK at $GO_MODULE_CANONICAL but go.mod names $generated_module; did the bridge change its layout?" >&2
  exit 1
}

log "Rewriting the Go module path to $GO_MODULE_PATH"
grep -rl "$GO_MODULE_CANONICAL" sdks/go | while IFS= read -r f; do
  # A literal, delimiter-safe replacement; the paths contain slashes and dots.
  python3 - "$f" "$GO_MODULE_CANONICAL" "$GO_MODULE_PATH" <<'PY'
import sys
path, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path) as fh:
    text = fh.read()
with open(path, "w") as fh:
    fh.write(text.replace(old, new))
PY
done

if grep -rq "$GO_MODULE_CANONICAL" sdks/go; then
  echo "the canonical module path survived the rewrite" >&2
  exit 1
fi

if [[ "$do_commit" != true ]]; then
  log "Left the regenerated SDKs uncommitted as requested"
  emit synced true
  exit 0
fi

git add -A sdks UPSTREAM_VERSION
if git diff --cached --quiet; then
  log "SDKs are byte-identical to the committed ones"
else
  git commit -m "Generate SDKs for terraform-aws-github-runner $tag

Mirrors $UPSTREAM_REPO@$tag via
'pulumi package add terraform-module $TF_MODULE $version $PACKAGE'."
  log "Committed the regenerated SDKs"
fi

# Two tags per release. The plain one names the repository's release, and is
# what the README and the other four SDKs refer to. The sdks/go/ prefixed one
# is the only form the Go module proxy accepts for a module in a subdirectory;
# without it `go get` can see the module but resolve no versions of it.
for t in "$tag" "$go_tag"; do
  if tag_exists "$t"; then
    log "Leaving the existing $t in place"
  else
    git tag -a "$t" -m "terraform-aws-github-runner $tag"
    log "Tagged $t"
  fi
done

emit synced true
