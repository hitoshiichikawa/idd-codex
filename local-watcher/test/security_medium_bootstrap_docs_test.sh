#!/usr/bin/env bash
#
# 用途: Issue #52 task 1 / 7 の bootstrap pinned reference / docs 同期を検証する。
# 配置先: local-watcher/test/security_medium_bootstrap_docs_test.sh
# 依存: bash 4+, git, grep, sed
# 実行: bash local-watcher/test/security_medium_bootstrap_docs_test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SETUP_SH="$REPO_ROOT/setup.sh"
README_MD="$REPO_ROOT/README.md"
QUICK_HOWTO_MD="$REPO_ROOT/QUICK-HOWTO.md"

PASS_COUNT=0
FAIL_COUNT=0

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "PASS: $label"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "FAIL: $label"
    echo "  expected: $(printf '%q' "$expected")"
    echo "  actual  : $(printf '%q' "$actual")"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

assert_contains_file() {
  local label="$1" path="$2" needle="$3"
  if grep -Fq -- "$needle" "$path"; then
    echo "PASS: $label"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "FAIL: $label"
    echo "  path: $path"
    echo "  needle: $needle"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

assert_not_contains_file() {
  local label="$1" path="$2" needle="$3"
  if grep -Fq -- "$needle" "$path"; then
    echo "FAIL: $label"
    echo "  path: $path"
    echo "  unexpected needle: $needle"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  else
    echo "PASS: $label"
    PASS_COUNT=$((PASS_COUNT + 1))
  fi
}

assert_match() {
  local label="$1" value="$2" regex="$3"
  if [[ "$value" =~ $regex ]]; then
    echo "PASS: $label"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "FAIL: $label"
    echo "  value: $(printf '%q' "$value")"
    echo "  regex: $regex"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

extract_pinned_ref() {
  sed -n 's/^IDD_CODEX_PINNED_REF="\([0-9a-fA-F]\{40\}\)"$/\1/p' "$SETUP_SH"
}

extract_raw_setup_refs() {
  grep -Eho 'raw\.githubusercontent\.com/hitoshiichikawa/idd-codex/[0-9a-fA-F]{40}/setup\.sh' \
    "$SETUP_SH" "$README_MD" "$QUICK_HOWTO_MD" \
    | sed -E 's#.*idd-codex/([0-9a-fA-F]{40})/setup\.sh#\1#' \
    | sort -u
}

TMPROOT=$(mktemp -d)
trap 'rm -rf "$TMPROOT"' EXIT

pinned_ref="$(extract_pinned_ref)"
assert_match "setup.sh declares a 40-hex pinned default ref (Req 1.2)" \
  "$pinned_ref" '^[0-9a-fA-F]{40}$'

raw_refs="$(extract_raw_setup_refs)"
assert_eq "README / QUICK-HOWTO / setup.sh raw setup URLs use the same pinned ref (Req 1.1)" \
  "$pinned_ref" "$raw_refs"

for path in "$SETUP_SH" "$README_MD" "$QUICK_HOWTO_MD"; do
  assert_not_contains_file "recommended setup URL avoids mutable main in $(basename "$path") (Req 1.1)" \
    "$path" "raw.githubusercontent.com/hitoshiichikawa/idd-codex/main/setup.sh"
done

assert_contains_file "setup.sh default IDD_CODEX_BRANCH resolves to pinned ref (Req 1.2 / NFR 1.1)" \
  "$SETUP_SH" "IDD_CODEX_BRANCH=\"\${IDD_CODEX_BRANCH:-\$IDD_CODEX_PINNED_REF}\""
assert_contains_file "setup.sh keeps IDD_CODEX_REPO_URL override name (Req 1.3 / NFR 1.1)" \
  "$SETUP_SH" "IDD_CODEX_REPO_URL=\"\${IDD_CODEX_REPO_URL:-https://github.com/hitoshiichikawa/idd-codex.git}\""
assert_contains_file "README documents mutable branch override as explicit override (Req 1.4)" \
  "$README_MD" 'IDD_CODEX_BRANCH=main'
assert_contains_file "README documents checksum verification path when artifacts exist (Req 1.5)" \
  "$README_MD" 'sha256sum -c SHA256SUMS'
assert_contains_file "QUICK-HOWTO documents checksum verification path when artifacts exist (Req 1.5)" \
  "$QUICK_HOWTO_MD" 'sha256sum -c SHA256SUMS'
assert_contains_file "README documents local runtime .bak recovery policy (Req 2.3 / NFR 2.1)" \
  "$README_MD" 'local runtime file recovery policy'
assert_contains_file "README documents local runtime dry-run actions (Req 2.3 / NFR 2.1)" \
  "$README_MD" 'DRY-RUN local runtime actions'
assert_contains_file "README documents Guard profile exact path handling (NFR 2.1 / NFR 2.2)" \
  "$README_MD" 'Guard profile exact path handling'
assert_contains_file "README documents secure tempfile fail-closed policy (Req 5.3 / NFR 2.1)" \
  "$README_MD" 'secure tempfile policy'
assert_contains_file "README documents generic PR Reviewer exec-failed comments (Req 4.2 / Req 4.4 / NFR 2.1)" \
  "$README_MD" 'generic exec-failed public comment'
assert_contains_file "README documents unchanged env labels and watcher paths migration note (NFR 1.1 / NFR 1.2 / NFR 1.3 / NFR 1.4)" \
  "$README_MD" 'Security hardening migration note'
assert_contains_file "QUICK-HOWTO documents mutable branch override as explicit override (Req 1.4)" \
  "$QUICK_HOWTO_MD" 'IDD_CODEX_BRANCH=main'
assert_contains_file "QUICK-HOWTO documents local runtime recovery summary (Req 2.3 / NFR 2.1)" \
  "$QUICK_HOWTO_MD" 'local runtime file recovery policy'

fixture_repo="$TMPROOT/fixture-src"
fixture_bare="$TMPROOT/fixture.git"
clone_sha="$TMPROOT/clone-sha"
clone_branch="$TMPROOT/clone-branch"
marker_sha="$TMPROOT/install-sha.marker"
marker_branch="$TMPROOT/install-branch.marker"

git init -q "$fixture_repo"
git -C "$fixture_repo" config user.email "test@example.invalid"
git -C "$fixture_repo" config user.name "Test User"
git -C "$fixture_repo" checkout -q -b main
cat > "$fixture_repo/install.sh" <<'FIXTURE_INSTALL'
#!/usr/bin/env bash
set -euo pipefail
: "${IDD_TEST_INSTALL_MARKER:?}"
git -C "$(dirname "$0")" rev-parse HEAD > "$IDD_TEST_INSTALL_MARKER"
printf 'args:%s\n' "$*" >> "$IDD_TEST_INSTALL_MARKER"
FIXTURE_INSTALL
chmod +x "$fixture_repo/install.sh"
git -C "$fixture_repo" add install.sh
git -C "$fixture_repo" commit -q -m "fixture install"
fixture_sha="$(git -C "$fixture_repo" rev-parse HEAD)"

git -C "$fixture_repo" checkout -q -b mutable-main
printf '\n# mutable branch fixture\n' >> "$fixture_repo/install.sh"
git -C "$fixture_repo" add install.sh
git -C "$fixture_repo" commit -q -m "fixture mutable branch"
mutable_sha="$(git -C "$fixture_repo" rev-parse HEAD)"
git -C "$fixture_repo" checkout -q main
git clone -q --bare "$fixture_repo" "$fixture_bare"

(
  cd "$REPO_ROOT"
  IDD_CODEX_REPO_URL="$fixture_bare" \
    IDD_CODEX_BRANCH="$fixture_sha" \
    IDD_CODEX_DIR="$clone_sha" \
    IDD_TEST_INSTALL_MARKER="$marker_sha" \
    bash "$SETUP_SH" --local >/dev/null
)
assert_eq "setup.sh can checkout an explicit commit SHA ref (Req 1.2)" \
  "$fixture_sha" "$(git -C "$clone_sha" rev-parse HEAD)"
assert_contains_file "setup.sh executes install.sh after commit SHA checkout (Req 1.2)" \
  "$marker_sha" "$fixture_sha"

(
  cd "$REPO_ROOT"
  IDD_CODEX_REPO_URL="$fixture_bare" \
    IDD_CODEX_BRANCH="mutable-main" \
    IDD_CODEX_DIR="$clone_branch" \
    IDD_TEST_INSTALL_MARKER="$marker_branch" \
    bash "$SETUP_SH" --repo /tmp/example >/dev/null
)
assert_eq "setup.sh honors IDD_CODEX_BRANCH mutable branch override (Req 1.3)" \
  "$mutable_sha" "$(git -C "$clone_branch" rev-parse HEAD)"
assert_contains_file "setup.sh executes install.sh after branch override checkout (Req 1.3)" \
  "$marker_branch" "$mutable_sha"

echo ""
echo "==========================================="
echo "PASS: $PASS_COUNT, FAIL: $FAIL_COUNT"
echo "==========================================="

if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi
