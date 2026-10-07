#!/usr/bin/env bash
# Unfiltered owning source checks; original executable and typed tests remain
# independent gates. No test execution or mock/compiler substitution occurs.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"
test "$(git rev-parse --show-toplevel)" = "$root"
count=0
while IFS= read -r -d '' source; do
	case "$source" in
		src/*.nim|tests/*.nim)
			nim check --path:src --hints:off --warnings:off "$source"
			count=$((count + 1))
			;;
		*.sh) bash -n "$source" ;;
		*.nix) nixfmt --check "$source" ;;
	esac
done < <(git ls-files -z)
test "$count" -gt 0
printf 'Checked every tracked Nim module: %s\n' "$count"
