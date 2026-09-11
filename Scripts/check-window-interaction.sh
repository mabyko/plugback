#!/bin/bash
# Read-only, human-operated input experiment; independent of the app and its saved profiles.
set -euo pipefail
probe_repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
probe_dir="$probe_repo/.build/window-interaction-probe"
mkdir -p "$probe_dir"
xcrun swiftc -swift-version 5 "$probe_repo/Scripts/window-interaction-probe.swift" -o "$probe_dir/window-interaction-probe"
if [[ "${1:-}" == "--check" || "${1:-}" == "--self-check" ]]; then
    exec "$probe_dir/window-interaction-probe" "$@"
fi
probe_log=$(mktemp "$probe_dir/run-XXXXXX")
printf 'Local trace: %s\n' "$probe_log" >&2
if [[ $# -gt 0 ]]; then
    "$probe_dir/window-interaction-probe" "$@" | tee "$probe_log"
    exit
fi

# Adapted from diagnosing-bugs/scripts/hitl-loop.template.sh.
# The agent can relay these prompts and the user's actual answers through a PTY.
step() {
    printf '\n>>> %s\n' "$1"
    read -r -p '준비되면 Enter: ' _
}
capture() {
    local answer
    read -r -t 180 -p "$2: " answer || return 1
    printf -v "$1" '%s' "$answer"
}

if ! "$probe_dir/window-interaction-probe" --check; then
    printf '\n관찰을 시작하지 못했습니다. 이 터미널에서 접근성 권한이 확인되지 않습니다. 이 메시지를 알려주세요.\n' >&2
    exit 2
fi
printf '\n준비 시간에는 기록하지 않습니다. Enter를 누른 뒤 3분 동안만 관찰합니다.\n'
step 'Chrome 일반 창을 준비하세요. 아직 창을 움직이지 마세요.'
"$probe_dir/window-interaction-probe" --seconds 180 > "$probe_log" &
probe_pid=$!
# Only this shell's own background job; a completed job cannot become an unrelated PID.
trap 'kill -INT %1 2>/dev/null || true' EXIT
probe_ready=false
for ((probe_attempt=0; probe_attempt<50; probe_attempt++)); do
    if [[ $(< "$probe_log") == *'"event":"ready"'* ]]; then
        probe_ready=true
        break
    fi
    if [[ $(< "$probe_log") == *'"event":"blocked"'* ]]; then
        break
    fi
    sleep 0.1
done
if [[ "$probe_ready" != true ]]; then
    printf '\n관찰 준비가 완료되지 않았습니다. 창을 조작하지 말고 이 메시지를 알려주세요.\n' >&2
    exit 2
fi
printf '\n관찰 시작. 지금부터 아래 동작을 해주세요.\n'
printf '\n① 제목 표시줄을 잡고 3초간 이동 ② 모서리를 잡고 3초간 크기 변경 ③ 페이지 글자를 3초간 드래그 선택. 동작 사이에 2초 쉬세요.\n'
printf '마치면 이 터미널로 돌아와 완료라고 입력하고 Enter를 누르세요.\n'
if ! capture PERFORMED '실제로 한 동작과 어려웠던 점 (모두 했으면 완료)'; then
    PERFORMED='관찰자 기록: 3분 안에 완료 입력이 없어 자동 종료됨. 실제 동작 수행 여부 미확인.'
    printf '\n시간 제한으로 관찰을 종료합니다. 기록은 성공으로 판정하지 않습니다.\n'
fi
printf '%s\n' "$PERFORMED" > "$probe_log.actions.txt"
kill -INT %1 2>/dev/null || true
wait "$probe_pid"
trap - EXIT
tail -n 1 "$probe_log"
printf 'Local trace: %s\nUser observations: %s.actions.txt\n' "$probe_log" "$probe_log"
