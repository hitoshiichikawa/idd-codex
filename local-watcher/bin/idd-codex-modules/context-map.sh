#!/usr/bin/env bash
# context-map.sh — per-task context-map 生成モジュール
#
# 用途:
#   per-task Implementer / Reviewer 起動前に watcher が生成する
#   docs/specs/<N>-<slug>/context-map.md の deterministic metadata 生成と
#   prompt 注入用 slice を提供する。
#
# 配置先:
#   $HOME/bin/idd-codex-modules/context-map.sh（install.sh が local-watcher/bin/idd-codex-modules/ から配置する）
#
# 依存:
#   - 本モジュールは idd-codex-issue-watcher.sh 本体から `source` される前提（単体起動しない）。
#   - `set -euo pipefail` は本体側で宣言済みのため、本モジュールでは宣言せず関数定義のみを持つ。
#   - グローバル変数（$REPO_DIR / $SPEC_DIR_REL / $LOG / $NUMBER / $BASE_BRANCH）は本体側で定義済み。
#   - 外部 CLI: date / git / awk / sed / head。
#
# セットアップ参照先:
#   README.md（context-map 試験機能） / install.sh（配置ロジック）

# ─── Per-task Context Map (#34 / #36 task 1) ───
#
# per-task Implementer / Reviewer が fresh context で毎回 repo 全体の当たりを付け直す
# token cost を抑えるため、watcher が task block / `_Boundary:_` / diff range / git grep
# から短い handoff metadata を生成する。task 1 時点では LLM Indexer を起動せず、
# 既存 deterministic contract と新規 opt-in gate の土台だけを提供する。

cm_context_map_enabled() {
  [ "${CONTEXT_MAP_ENABLED:-false}" = "true" ]
}

ci_context_indexer_enabled() {
  [ "${CONTEXT_INDEXER_ENABLED:-false}" = "true" ]
}

cm_log() {
  if [ -n "${LOG:-}" ]; then
    echo "[$(date '+%F %T')] context-map: $*" >> "$LOG"
  fi
}

ci_log() {
  if [ -n "${LOG:-}" ]; then
    echo "[$(date '+%F %T')] context-indexer: $*" >> "$LOG"
  fi
}

cm_warn() {
  if [ -n "${LOG:-}" ]; then
    echo "[$(date '+%F %T')] context-map WARN: $*" >> "$LOG"
  else
    echo "context-map WARN: $*" >&2
  fi
}

cm_context_map_path() {
  printf '%s/%s/context-map.md\n' "$REPO_DIR" "$SPEC_DIR_REL"
}

cm_unique_nonempty() {
  local limit="${1:-40}"
  awk 'NF && !seen[$0]++ { print }' | head -n "$limit"
}

cm_normalize_path_candidates() {
  sed -E \
    -e 's/^`//' \
    -e 's/`$//' \
    -e 's#^\./##' \
    -e 's/[),.;:]+$//' \
    -e 's#//+#/#g' |
    awk '
      NF == 0 { next }
      /^https?:/ { next }
      /^\$/ { next }
      /^[A-Za-z0-9_.\/-]+$/ { print }
    '
}

cm_extract_task_block() {
  local tasks_md="$1"
  local task_id="$2"

  if [ ! -f "$tasks_md" ] || [ -z "$task_id" ]; then
    return 0
  fi

  awk -v target="$task_id" '
    function task_id_from_line(line, rest) {
      if (line !~ /^- \[[ x]\]\*? ([0-9]+\.|[0-9]+\.[0-9]+(\.[0-9]+)*) /) {
        return ""
      }
      rest = line
      sub(/^- \[[ x]\]\*? /, "", rest)
      sub(/ .*/, "", rest)
      sub(/\.$/, "", rest)
      return rest
    }
    BEGIN {
      in_block = 0
      prefix = target "."
    }
    {
      current = task_id_from_line($0)
      if (in_block == 1) {
        if (current != "" && current != target && index(current, prefix) != 1) {
          exit
        }
        print
        next
      }
      if (current == target) {
        in_block = 1
        print
      }
    }
  ' "$tasks_md"
}

cm_extract_metadata_value() {
  local key="$1"
  awk -v key="$key" '
    index($0, key) {
      line = $0
      sub("^.*" key "[[:space:]]*", "", line)
      print line
      found = 1
      exit
    }
    END {
      if (found != 1) {
        exit 1
      }
    }
  '
}

cm_extract_path_candidates_from_text() {
  awk '
    {
      line = $0
      while (match(line, /`[^`]+`/)) {
        token = substr(line, RSTART + 1, RLENGTH - 2)
        if (token ~ /(^|\/)[A-Za-z0-9_.-]+\.(sh|md|ya?ml|json|tmpl|txt)$/ || token ~ /\//) {
          print token
        }
        line = substr(line, RSTART + RLENGTH)
      }

      line = $0
      while (match(line, /[A-Za-z0-9_.\/-]+\.(sh|md|ya?ml|json|tmpl|txt)/)) {
        print substr(line, RSTART, RLENGTH)
        line = substr(line, RSTART + RLENGTH)
      }
    }
  ' | cm_normalize_path_candidates | cm_unique_nonempty 80
}

cm_extract_anchor_candidates_from_text() {
  awk '
    {
      line = $0
      while (match(line, /`[A-Za-z_][A-Za-z0-9_]*`/)) {
        token = substr(line, RSTART + 1, RLENGTH - 2)
        print token
        line = substr(line, RSTART + RLENGTH)
      }
    }
  ' | cm_unique_nonempty 30
}

cm_collect_changed_files() {
  local range_start="${1:-}"
  local range_end="${2:-}"

  if [ -n "$range_start" ] && [ -n "$range_end" ]; then
    git -C "$REPO_DIR" diff --name-only "${range_start}..${range_end}" 2>/dev/null || true
    return 0
  fi

  if git -C "$REPO_DIR" rev-parse --verify "${BASE_BRANCH:-main}" >/dev/null 2>&1; then
    git -C "$REPO_DIR" diff --name-only "${BASE_BRANCH:-main}..HEAD" 2>/dev/null || true
  fi
}

cm_collect_tests_for_anchors() {
  local anchors="$1"
  local anchor

  if [ -z "$anchors" ]; then
    return 0
  fi

  while IFS= read -r anchor; do
    [ -n "$anchor" ] || continue
    git -C "$REPO_DIR" grep -l -- "$anchor" -- 'local-watcher/test/*.sh' 2>/dev/null || true
  done <<<"$anchors" | cm_unique_nonempty 30
}

cm_filter_context_paths() {
  local kind="$1"
  local path

  while IFS= read -r path; do
    [ -n "$path" ] || continue
    case "$kind" in
      test)
        case "$path" in
          local-watcher/test/*|*/test/*|*_test.sh|*test*.sh) printf '%s\n' "$path" ;;
        esac
        ;;
      doc)
        case "$path" in
          README.md|AGENTS.md|docs/*|.codex/*|repo-template/.codex/*|*requirements.md|*design.md|*tasks.md|*impl-notes.md|*review-notes.md) printf '%s\n' "$path" ;;
        esac
        ;;
      target)
        case "$path" in
          local-watcher/test/*|*/test/*|*_test.sh|*test*.sh|README.md|AGENTS.md|docs/*|.codex/*|repo-template/.codex/*|*requirements.md|*design.md|*tasks.md|*impl-notes.md|*review-notes.md) : ;;
          *) printf '%s\n' "$path" ;;
        esac
        ;;
    esac
  done | cm_unique_nonempty 30
}

ci_range_key() {
  local range_start="${1:-}"
  local range_end="${2:-}"

  if [ -n "$range_start" ] || [ -n "$range_end" ]; then
    printf '%s..%s\n' "${range_start:-unknown}" "${range_end:-unknown}"
  else
    printf '%s\n' "none"
  fi
}

ci_collect_indexer_markers() {
  local path="$1"

  if [ ! -f "$path" ]; then
    return 0
  fi

  awk '/^<!-- context-indexer: / { print }' "$path"
}

ci_marker_seen() {
  local task_id="$1"
  local stage="$2"
  local range_start="${3:-}"
  local range_end="${4:-}"
  local context_path range_key

  context_path="$(cm_context_map_path)"
  range_key="$(ci_range_key "$range_start" "$range_end")"

  if [ ! -f "$context_path" ]; then
    return 1
  fi

  awk -v task="$task_id" -v stage="$stage" -v range="$range_key" '
    /^<!-- context-indexer: / {
      if (index($0, " task=" task " ") &&
          index($0, " stage=" stage " ") &&
          index($0, " range=" range " ") &&
          ($0 ~ / result=success / || $0 ~ / result=fallback /)) {
        found = 1
        exit
      }
    }
    END {
      exit(found == 1 ? 0 : 1)
    }
  ' "$context_path"
}

ci_normalize_reason_token() {
  local reason="${1:-unknown}"

  printf '%s\n' "$reason" |
    sed -E 's/[^A-Za-z0-9_.-]+/-/g; s/^-+//; s/-+$//' |
    awk 'NF { print; found = 1 } END { if (found != 1) print "unknown" }'
}

ci_record_indexer_marker() {
  local task_id="$1"
  local stage="$2"
  local range_start="${3:-}"
  local range_end="${4:-}"
  local result="${5:-}"
  local reason="${6:-unknown}"
  local context_path range_key reason_token

  case "$result" in
    success|fallback) ;;
    *) return 1 ;;
  esac

  context_path="$(cm_context_map_path)"
  range_key="$(ci_range_key "$range_start" "$range_end")"
  reason_token="$(ci_normalize_reason_token "$reason")"

  mkdir -p "$(dirname "$context_path")"
  if ci_marker_seen "$task_id" "$stage" "$range_start" "$range_end"; then
    return 0
  fi

  printf '\n<!-- context-indexer: task=%s stage=%s range=%s result=%s reason=%s -->\n' \
    "$task_id" "$stage" "$range_key" "$result" "$reason_token" >> "$context_path"
}

ci_has_non_spec_context_path() {
  local target_paths="$1"
  local doc_paths="$2"
  local path

  while IFS= read -r path; do
    [ -n "$path" ] || continue
    return 0
  done <<<"$target_paths"

  while IFS= read -r path; do
    [ -n "$path" ] || continue
    case "$path" in
      "$SPEC_DIR_REL"/*) ;;
      *) return 0 ;;
    esac
  done <<<"$doc_paths"

  return 1
}

ci_boundary_docs_only() {
  local boundary="$1"
  local doc_paths="$2"
  local boundary_paths path has_boundary_path=0 has_non_spec_doc=0

  boundary_paths="$(printf '%s\n' "$boundary" | cm_extract_path_candidates_from_text)"
  if [ -z "$boundary_paths" ]; then
    return 1
  fi

  while IFS= read -r path; do
    [ -n "$path" ] || continue
    has_boundary_path=1
    case "$path" in
      README.md|AGENTS.md|docs/*|.codex/*|repo-template/.codex/*|*requirements.md|*design.md|*tasks.md|*impl-notes.md|*review-notes.md) ;;
      *) return 1 ;;
    esac
  done <<<"$boundary_paths"

  while IFS= read -r path; do
    [ -n "$path" ] || continue
    case "$path" in
      "$SPEC_DIR_REL"/*) ;;
      *) has_non_spec_doc=1 ;;
    esac
  done <<<"$doc_paths"

  [ "$has_boundary_path" -eq 1 ] && [ "$has_non_spec_doc" -eq 1 ]
}

ci_context_needs_indexer() {
  local task_id="$1"
  local stage="${2:-unknown}"
  local range_start="${3:-}"
  local range_end="${4:-}"

  if ! ci_context_indexer_enabled; then
    printf '%s\n' "skip:disabled"
    return 0
  fi

  if ci_marker_seen "$task_id" "$stage" "$range_start" "$range_end"; then
    printf '%s\n' "skip:already-run"
    return 0
  fi

  local tasks_md="$REPO_DIR/$SPEC_DIR_REL/tasks.md"
  if [ ! -f "$tasks_md" ]; then
    printf '%s\n' "needed:tasks-md-missing"
    return 0
  fi

  local task_block boundary requirements anchors path_candidates changed_files sufficiency_changed_files anchor_tests all_paths target_paths test_paths doc_paths
  task_block="$(cm_extract_task_block "$tasks_md" "$task_id")"
  if [ -z "$task_block" ]; then
    printf '%s\n' "needed:task-block-missing"
    return 0
  fi

  boundary="$(printf '%s\n' "$task_block" | cm_extract_metadata_value "_Boundary:_" 2>/dev/null || true)"
  requirements="$(printf '%s\n' "$task_block" | cm_extract_metadata_value "_Requirements:_" 2>/dev/null || true)"
  anchors="$(printf '%s\n' "$task_block" | cm_extract_anchor_candidates_from_text)"
  path_candidates="$(printf '%s\n' "$task_block" | cm_extract_path_candidates_from_text)"
  changed_files="$(cm_collect_changed_files "$range_start" "$range_end")"
  sufficiency_changed_files=""
  if [ -n "$range_start" ] && [ -n "$range_end" ]; then
    sufficiency_changed_files="$changed_files"
  fi
  anchor_tests="$(cm_collect_tests_for_anchors "$anchors")"

  all_paths="$(
    {
      printf '%s\n' "$path_candidates"
      printf '%s\n' "$sufficiency_changed_files"
      printf '%s\n' "$anchor_tests"
      printf '%s\n' "$SPEC_DIR_REL/requirements.md"
      printf '%s\n' "$SPEC_DIR_REL/design.md"
      printf '%s\n' "$SPEC_DIR_REL/tasks.md"
      if [ -f "$REPO_DIR/$SPEC_DIR_REL/impl-notes.md" ]; then
        printf '%s\n' "$SPEC_DIR_REL/impl-notes.md"
      fi
    } | cm_normalize_path_candidates | cm_unique_nonempty 80
  )"
  target_paths="$(printf '%s\n' "$all_paths" | cm_filter_context_paths target)"
  test_paths="$(printf '%s\n' "$all_paths" | cm_filter_context_paths test)"
  doc_paths="$(printf '%s\n' "$all_paths" | cm_filter_context_paths doc)"

  if [ -z "$requirements" ]; then
    printf '%s\n' "needed:requirements-missing"
    return 0
  fi
  if [ -z "$boundary" ] || [ "$boundary" = "(not found)" ]; then
    printf '%s\n' "needed:boundary-missing"
    return 0
  fi
  if [ "$stage" = "reviewer" ] && { [ -n "$range_start" ] || [ -n "$range_end" ]; } && [ -z "$changed_files" ]; then
    printf '%s\n' "needed:diff-empty"
    return 0
  fi
  if ! ci_has_non_spec_context_path "$target_paths" "$doc_paths"; then
    printf '%s\n' "needed:candidates-missing"
    return 0
  fi
  if ci_boundary_docs_only "$boundary" "$doc_paths"; then
    printf '%s\n' "skip:sufficient-docs-only"
    return 0
  fi
  if [ -z "$anchors" ] && [ -z "$test_paths" ]; then
    printf '%s\n' "needed:anchors-tests-missing"
    return 0
  fi

  printf '%s\n' "skip:sufficient"
}

cm_print_md_list() {
  local items="$1"
  local item

  if [ -z "$items" ]; then
    printf '%s\n' "- (none)"
    return 0
  fi

  while IFS= read -r item; do
    [ -n "$item" ] || continue
    printf '%s\n' "- \`$item\`"
  done <<<"$items"
}

cm_write_context_map() {
  local task_id="$1"
  local stage="${2:-unknown}"
  local range_start="${3:-}"
  local range_end="${4:-}"

  cm_context_map_enabled || return 0

  local tasks_md="$REPO_DIR/$SPEC_DIR_REL/tasks.md"
  local out_path
  out_path="$(cm_context_map_path)"

  if [ ! -f "$tasks_md" ]; then
    cm_warn "skip: tasks.md not found path=$tasks_md"
    return 0
  fi

  local task_block boundary requirements depends anchors path_candidates changed_files anchor_tests all_paths target_paths test_paths doc_paths
  local existing_indexer_markers indexer_decision
  task_block="$(cm_extract_task_block "$tasks_md" "$task_id")"
  boundary="$(printf '%s\n' "$task_block" | cm_extract_metadata_value "_Boundary:_" 2>/dev/null || true)"
  requirements="$(printf '%s\n' "$task_block" | cm_extract_metadata_value "_Requirements:_" 2>/dev/null || true)"
  depends="$(printf '%s\n' "$task_block" | cm_extract_metadata_value "_Depends:_" 2>/dev/null || true)"
  anchors="$(printf '%s\n' "$task_block" | cm_extract_anchor_candidates_from_text)"
  path_candidates="$(printf '%s\n' "$task_block" | cm_extract_path_candidates_from_text)"
  changed_files="$(cm_collect_changed_files "$range_start" "$range_end")"
  anchor_tests="$(cm_collect_tests_for_anchors "$anchors")"

  all_paths="$(
    {
      printf '%s\n' "$path_candidates"
      printf '%s\n' "$changed_files"
      printf '%s\n' "$anchor_tests"
      printf '%s\n' "$SPEC_DIR_REL/requirements.md"
      printf '%s\n' "$SPEC_DIR_REL/design.md"
      printf '%s\n' "$SPEC_DIR_REL/tasks.md"
      if [ -f "$REPO_DIR/$SPEC_DIR_REL/impl-notes.md" ]; then
        printf '%s\n' "$SPEC_DIR_REL/impl-notes.md"
      fi
    } | cm_normalize_path_candidates | cm_unique_nonempty 80
  )"
  target_paths="$(printf '%s\n' "$all_paths" | cm_filter_context_paths target)"
  test_paths="$(printf '%s\n' "$all_paths" | cm_filter_context_paths test)"
  doc_paths="$(printf '%s\n' "$all_paths" | cm_filter_context_paths doc)"
  existing_indexer_markers="$(ci_collect_indexer_markers "$out_path")"

  mkdir -p "$(dirname "$out_path")"
  local tmp_path="${out_path}.tmp"
  {
    printf '%s\n' "# Context Map"
    printf '\n'
    printf '%s\n' "watcher が \`CONTEXT_MAP_ENABLED=true\` の per-task 実行前に生成した短い探索地図です。"
    printf '%s\n' "agent はこの map を最初に参照し、不足時だけ targeted search を追加してください。"
    printf '\n'
    printf '%s\n' "## Metadata"
    printf '%s\n' "- Issue: #${NUMBER:-unknown}"
    printf '%s\n' "- Stage: \`${stage}\`"
    printf '%s\n' "- Task: \`${task_id}\`"
    printf '%s\n' "- Spec dir: \`${SPEC_DIR_REL}\`"
    printf '%s\n' "- Generated at: \`$(date '+%Y-%m-%d %H:%M:%S %z')\`"
    if [ -n "$range_start" ] || [ -n "$range_end" ]; then
      printf '%s\n' "- Diff range: \`${range_start:-unknown}..${range_end:-unknown}\`"
    fi
    printf '\n'
    printf '%s\n' "## Task Block"
    printf '%s\n' '```markdown'
    if [ -n "$task_block" ]; then
      printf '%s\n' "$task_block"
    else
      printf '%s\n' "(task block not found in tasks.md)"
    fi
    printf '%s\n' '```'
    printf '\n'
    printf '%s\n' "## Requirements"
    printf '%s\n' "${requirements:-(not found)}"
    printf '\n'
    printf '%s\n' "## Boundary"
    printf '%s\n' "${boundary:-(not found)}"
    printf '\n'
    printf '%s\n' "## Depends"
    printf '%s\n' "${depends:-(none)}"
    printf '\n'
    printf '%s\n' "## Candidate Files"
    cm_print_md_list "$target_paths"
    printf '\n'
    printf '%s\n' "## Candidate Tests"
    cm_print_md_list "$test_paths"
    printf '\n'
    printf '%s\n' "## Candidate Docs"
    cm_print_md_list "$doc_paths"
    printf '\n'
    printf '%s\n' "## Anchors"
    cm_print_md_list "$anchors"
    printf '\n'
    printf '%s\n' "## Exploration Constraints"
    printf '%s\n' "- まず Candidate Files / Candidate Tests / Anchors を確認する。"
    printf '%s\n' "- repo-wide \`rg --files\` や README 全体読みは、候補が不足した場合だけ実行する。"
    printf '%s\n' "- ファイル全体を読む前に、anchor 周辺の小さい範囲を読む。"
    printf '%s\n' "- Reviewer は対象 task の diff range と \`_Requirements:_\` / \`_Boundary:_\` に判定を限定する。"
    printf '%s\n' "- この map は補助情報であり、最終判断は \`tasks.md\` と実際の diff で検証する。"
    if [ -n "$existing_indexer_markers" ]; then
      printf '\n'
      printf '%s\n' "$existing_indexer_markers"
    fi
  } > "$tmp_path"
  mv "$tmp_path" "$out_path"

  cm_log "updated path=${SPEC_DIR_REL}/context-map.md task=${task_id} stage=${stage}"
  indexer_decision="$(ci_context_needs_indexer "$task_id" "$stage" "$range_start" "$range_end")"
  ci_log "task=${task_id} stage=${stage} decision=${indexer_decision}"
}

cm_build_prompt_block() {
  cm_context_map_enabled || return 0

  local context_path
  context_path="$(cm_context_map_path)"
  if [ ! -f "$context_path" ]; then
    return 0
  fi

  cat <<EOF

## Context Map（watcher 生成 / CONTEXT_MAP_ENABLED=true）

以下は watcher が task ごとに生成した短い探索地図です。まずこの map の候補ファイル /
anchors / tests を確認し、repo 全体の広域探索は不足時だけ行ってください。

- Path: \`${SPEC_DIR_REL}/context-map.md\`
- 扱い: 参照専用。実装 commit / \`docs(tasks): mark <id> as done\` commit には含めないこと

\`\`\`markdown
$(sed -n '1,180p' "$context_path")
\`\`\`
EOF
}
