#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

errors=0
warnings=0
strict="${STANDARDS_STRICT:-0}"
if [[ -z "${STANDARDS_STRICT:-}" && -n "${GITHUB_ACTIONS:-}" ]]; then
  strict=1
fi

report_violation() {
  local message="$1"
  local detail="${2:-}"

  if [[ "$strict" == "1" ]]; then
    echo "ERROR: $message"
    [[ -n "$detail" ]] && echo "$detail"
    errors=$((errors + 1))
  else
    echo "WARN: $message"
    [[ -n "$detail" ]] && echo "$detail"
    warnings=$((warnings + 1))
  fi
}

required_files=(
  "droidz/standards/README.md"
  "droidz/standards/code-style.md"
  "droidz/standards/error-handling.md"
  "droidz/standards/async-patterns.md"
  "droidz/standards/tool-implementation.md"
  "droidz/standards/database.md"
  "droidz/standards/testing.md"
  "droidz/standards/security.md"
  "droidz/standards/feature-parity.md"
  "droidz/standards/review-discipline.md"
  "droidz/standards/commits-and-prs.md"
  "droidz/standards/adding-features.md"
)

echo "=== Standards Check ==="
echo "[1/4] Validating standards files"
for file in "${required_files[@]}"; do
  if [[ ! -f "$file" ]]; then
    echo "ERROR: Missing required standards file: $file"
    errors=$((errors + 1))
  fi
done

resolve_base_ref() {
  if [[ -n "${GITHUB_BASE_REF:-}" ]] && git show-ref --verify --quiet "refs/remotes/origin/${GITHUB_BASE_REF}"; then
    echo "origin/${GITHUB_BASE_REF}"
    return
  fi

  if git show-ref --verify --quiet "refs/remotes/origin/main"; then
    echo "origin/main"
    return
  fi

  if git rev-parse --verify --quiet "HEAD~1" >/dev/null; then
    echo "HEAD~1"
    return
  fi

  echo "HEAD"
}

collect_added_lines() {
  python3 - <<'PY'
import re
import sys

line = None
for raw in sys.stdin:
    if raw.startswith('@@'):
        match = re.search(r'\+(\d+)', raw)
        line = int(match.group(1)) if match else None
        continue

    if raw.startswith('+++') or raw.startswith('---'):
        continue

    if raw.startswith('+'):
        if line is None:
            continue
        print(f"{line}\t{raw[1:].rstrip()}")
        line += 1
        continue

    if raw.startswith('-'):
        continue

    if line is not None:
        line += 1
PY
}

first_test_line() {
  local file="$1"
  local line

  line="$(rg -n -m1 '^\s*#\[cfg\(test\)\]' "$file" | cut -d: -f1 || true)"
  if [[ -z "$line" ]]; then
    line="$(rg -n -m1 '^\s*mod\s+tests\s*\{' "$file" | cut -d: -f1 || true)"
  fi

  echo "$line"
}

diff_mode="local"
diff_range=""
if [[ -n "${GITHUB_BASE_REF:-}" || -n "${GITHUB_ACTIONS:-}" ]]; then
  diff_mode="ci"
  base_ref="$(resolve_base_ref)"
  if [[ "$base_ref" == "HEAD" ]]; then
    diff_range="HEAD"
  else
    merge_base="$(git merge-base HEAD "$base_ref" 2>/dev/null || echo "$base_ref")"
    diff_range="${merge_base}...HEAD"
  fi
fi

changed_files=()
if [[ "$diff_mode" == "ci" ]]; then
  while IFS= read -r file; do
    [[ -n "$file" ]] && changed_files+=("$file")
  done < <(git diff --name-only --diff-filter=ACMRT "$diff_range" || true)
else
  while IFS= read -r file; do
    [[ -n "$file" ]] && changed_files+=("$file")
  done < <({
    git diff --name-only --diff-filter=ACMRT HEAD || true
    git ls-files --others --exclude-standard || true
  } | sed '/^$/d' | sort -u)
fi

diff_for_file() {
  local file="$1"
  if [[ "$diff_mode" == "ci" ]]; then
    git diff -U0 "$diff_range" -- "$file"
  else
    git diff -U0 HEAD -- "$file"
  fi
}

echo "[2/4] Checking newly added Rust code for unwrap/expect in src/"
for file in "${changed_files[@]}"; do
  [[ "$file" =~ ^src/.*\.rs$ ]] || continue
  [[ -f "$file" ]] || continue

  test_line="$(first_test_line "$file")"
  file_diff="$(diff_for_file "$file")"
  added_lines="$(printf '%s\n' "$file_diff" | collect_added_lines)"

  while IFS=$'\t' read -r line_no line_text; do
    [[ -n "$line_no" ]] || continue

    if [[ -n "$test_line" && "$line_no" -ge "$test_line" ]]; then
      continue
    fi

    if printf '%s\n' "$line_text" | rg -q '\.unwrap\(\)|\.expect\('; then
      report_violation "Added unwrap/expect usage in ${file}:${line_no}" "+${line_text}"
    fi
  done <<< "$added_lines"
done

echo "[3/4] Checking newly added production super:: imports/usages in src/"
for file in "${changed_files[@]}"; do
  [[ "$file" =~ ^src/.*\.rs$ ]] || continue
  [[ -f "$file" ]] || continue

  test_line="$(first_test_line "$file")"
  file_diff="$(diff_for_file "$file")"
  added_lines="$(printf '%s\n' "$file_diff" | collect_added_lines)"

  while IFS=$'\t' read -r line_no line_text; do
    [[ -n "$line_no" ]] || continue

    if [[ -n "$test_line" && "$line_no" -ge "$test_line" ]]; then
      continue
    fi

    if printf '%s\n' "$line_text" | rg -q '\bsuper::'; then
      if printf '%s\n' "$line_text" | rg -q '^\s*use\s+super::\*\s*;\s*$'; then
        continue
      fi
      report_violation "Added super:: usage in ${file}:${line_no} (prefer crate::)" "+${line_text}"
    fi
  done <<< "$added_lines"
done

echo "[4/4] Feature parity reminder"
src_changed=false
feature_parity_changed=false

for file in "${changed_files[@]}"; do
  if [[ "$file" =~ ^src/ ]]; then
    src_changed=true
  fi
  if [[ "$file" == "FEATURE_PARITY.md" ]]; then
    feature_parity_changed=true
  fi
done

if [[ "$src_changed" == true && "$feature_parity_changed" == false ]]; then
  echo "WARN: src/ changed but FEATURE_PARITY.md was not updated."
  echo "      If feature behavior/status changed, update FEATURE_PARITY.md in this branch."
  warnings=$((warnings + 1))
fi

echo "=== Completed: ${errors} error(s), ${warnings} warning(s) ==="
if [[ "$errors" -ne 0 ]]; then
  exit 1
fi
