#!/usr/bin/env bash
# parser-drain — host-측 결정형 파싱 드레인 (watchdog 밖, concurrency=1, 멱등).
# sources/00_inbox 의 미파싱 바이너리를 2nd-brain-parser 컨테이너로 순차 파싱.
#   PDF      → docling.json + mineru.json + diff.json (듀얼+diff, Phase 2)
#   비-PDF   → docling.json (mineru=PDF 전용, diff 불가)
#   이미지   → ocr.json (parse-ocr; device-adaptive 로컬 OCR, docling/mineru N/A)
# 검증·노트화(diverge 시 LLM 결정 = Phase 3)는 brainify(별도).
#
# 트리거: parser-drain.timer (host systemd-user). 게이트웨이는 파일만 드롭.
# 안정: systemd 단일인스턴스 + flock + 순차루프 = concurrency=1 (RAM 보호).
#      각 엔진 timeout 가드(MinerU CPU deadlock 등 hang 시 그 파일만 실패·계속).
set -euo pipefail

export SB_DATA="${SB_DATA:-$HOME/projects/2nd-brain-vault}"   # compose 마운트
REPO="${SECOND_BRAIN_REPO:-$HOME/projects/2nd-brain}"
INBOX="$SB_DATA/sources/00_inbox"
CMNT="/home/user/projects/2nd-brain-vault"                    # 컨테이너 내부 마운트 경로
PARSER_CLI="${PARSER_CLI:-brain-pdf}"                         # 컨테이너 내 CLI 명(이미지 0.2.0~ brain-pdf, 구명 2nd-brain-parser)
ENGINE_TIMEOUT="${ENGINE_TIMEOUT:-900}"                       # 엔진당 상한(초)
LOG="${PARSER_DRAIN_LOG:-$HOME/.local/state/parser-drain.log}"
mkdir -p "$(dirname "$LOG")"
log(){ echo "$(date -Is) $*" >>"$LOG"; }

# ── 모드 ──────────────────────────────────────────────────────────────────────
# `--alert-only` = 파싱하지 않고 **현재 쌓인 `.parse-error` 를 훑어 알림만 재발송**한다.
# 모든 알림은 자동발화와 1회성 호출 **양쪽**이 되어야 한다는 원칙(Dr. Ben, 2026-08-07).
# 즉시 알림은 원래 런 안에서만 나가서 "지금 밀린 실패 다시 보내줘" 를 할 수단이 없었다.
# 읽기 전용이므로 flock 도 컨테이너도 잡지 않는다 — 드레인이 도는 중에도 안전하게 부를 수 있다.
ALERT_ONLY=0
[ "${1:-}" = "--alert-only" ] && ALERT_ONLY=1

if [ "$ALERT_ONLY" != 1 ]; then
  # ── concurrency=1 ──
  exec 9>"/run/user/$(id -u)/parser-drain.lock"
  flock -n 9 || { log "already running, skip"; exit 0; }
  [ -d "$INBOX" ] || { log "no inbox: $INBOX"; exit 0; }

  # ── warm 데몬 1회 기동, 종료 시 teardown ──
  cd "$REPO/docker"
  mapfile -t CF < <(./scripts/detect-compose.sh)
  COMPOSE=(docker compose ${CF[*]})
  "${COMPOSE[@]}" up -d 2nd-brain-parser >>"$LOG" 2>&1
  trap '"${COMPOSE[@]}" down >>"$LOG" 2>&1 || true' EXIT
fi

# 엔진 1회 실행 → host 파일로 atomic 기록. $1=host출력, $2..=parser CLI 인자(컨테이너 경로)
# 실패 시 마지막 오류 줄을 LAST_ERR 에 담는다 — 마커에 사유를 남기기 위해서다(아래 mark_error).
LAST_ERR=""
run_to(){
  local out="$1"; shift
  local tmp="$out.tmp" errf rc
  errf="$(mktemp)"; LAST_ERR=""
  timeout "$ENGINE_TIMEOUT" docker exec 2nd-brain-parser "$PARSER_CLI" "$@" >"$tmp" 2>"$errf"; rc=$?
  cat "$errf" >>"$LOG"
  if [ "$rc" = 0 ] && [ -s "$tmp" ]; then rm -f "$errf"; mv -f "$tmp" "$out"; return 0; fi
  LAST_ERR="$(grep -aiE 'error|exception|not running|denied' "$errf" | tail -1)"
  [ -z "$LAST_ERR" ] && LAST_ERR="$(tail -1 "$errf" 2>/dev/null)"
  [ -z "$LAST_ERR" ] && LAST_ERR="빈 출력(rc=$rc)"
  # 124 = timeout(1) 이 보낸 종료코드. **파일 결함이 아니라 시간 상한**이라 반드시 구분한다 —
  # 2026-08-06 실측: 6MB PDF 가 900초 정각에 죽었는데 마커엔 사유가 없어 '파싱 불가'로 오독됐다.
  [ "$rc" = 124 ] && LAST_ERR="timeout ${ENGINE_TIMEOUT}s | ${LAST_ERR}"
  LAST_ERR="${LAST_ERR:0:400}"
  rm -f "$errf" "$tmp"; return 1
}

# 실패 마커 — 사유·시각·단계를 남긴다. $1=_parse dir  $2=단계  $3=원본 경로
#
# 예전엔 `: >"$out/.parse-error"` 로 **빈 파일**만 만들었다. 그래서 마커 26개를 놓고도
# "왜 실패했나"를 알 수 없어 하나씩 재현해야 했고(2026-08-06), 타임아웃·암호화·인프라 사고가
# 전부 같은 얼굴이었다. 사유 한 줄이 그 재현 작업을 통째로 없앤다.
mark_error(){
  printf 'ts: %s\nhost: %s\nstage: %s\nsource: %s\nreason: %s\n' \
    "$(date -Is)" "$(hostname)" "$2" "$3" "${LAST_ERR:-(사유 미상)}" >"$1/.parse-error" 2>/dev/null || true
  NEWFAIL+=("$2|$3|${LAST_ERR:-(사유 미상)}")   # 이번 런의 신규 실패 — 끝에서 한 번에 알린다
}

# 성공하면 마커를 지운다. **이 동작이 없었다**(2026-08-06 발견) — 한 번 실패한 파일은 나중에
# 성공해도 마커가 남아, `.parse-error` 개수가 '현재 미해결'이 아니라 '실패한 적 있는 파일의
# 누적 명부'였다. 실제로 재시도에서 통과한 4건이 계속 실패로 집계되고 있었다.
clear_error(){ rm -f "$1/.parse-error" 2>/dev/null || true; }

# ── 신규 실패 즉시 알림 (2026-08-07) ────────────────────────────────────────────
# `.parse-error` 는 그동안 **아무 데서도 집계되지 않았다** — 드레인 보고의 "파싱오류 stub" 은
# 노트의 parse_confidence:low 를 세는 것이고, 헬스체크에도 항목이 없었다. 그래서 26건이
# 몇 달간 조용히 쌓였고 손으로 찾아보기 전까지 아무도 몰랐다(2026-08-06 발견).
#
# 실패는 드물다(hwp 181개 중 1개 실패). 드물기 때문에 **즉시 알려도 소음이 안 된다** —
# 성공에는 침묵하고 실패에만 말한다. 아침 헬스체크의 누적 보고와 역할이 다르다:
# 즉시 알림 = "지금 조치하라", 아침 = "아직 안 치웠다".
#
# ★ 폭주 방지: 이번 런에서 **새로 생긴** 마커만 모으고, 메시지에는 최대 MAX 건만 적는다.
#   파서가 통째로 깨지면 수십 건이 한 런에 쏟아질 수 있는데, 그때 수십 통을 보내면
#   알림 자체가 무의미해진다. 나머지는 "…외 N건" 으로 **밝히고** 줄인다.
NEWFAIL=()
ALERT_MAX="${PARSER_DRAIN_ALERT_MAX:-5}"
TG_CHAT="${PARSER_DRAIN_TG_CHAT:-8669227844}"
OPENCLAW_JSON="${OPENCLAW_JSON:-$HOME/.openclaw/openclaw.json}"

tg_send(){   # $1=text. 비-fatal — 알림 실패가 파싱 결과를 무효화하지 않는다.
  local text="$1" token
  token="${PARSER_DRAIN_TG_TOKEN:-$(python3 -c "import json;print(json.load(open('$OPENCLAW_JSON'))['channels']['telegram']['botToken'])" 2>/dev/null || true)}"
  # 토큰이 없으면 **보내려던 문안을 로그에 남긴다** — 조용히 사라지면 알림이 도는지
  # 안 도는지 알 수 없다(자동화를 끈 자리는 그 사실이 남아야 한다).
  [ -z "$token" ] && { log "tg: no token — alert skip. 문안:"; printf '%s\n' "$text" >>"$LOG"; return 0; }
  curl -sS --max-time 20 "https://api.telegram.org/bot${token}/sendMessage" \
    --data-urlencode "chat_id=${TG_CHAT}" --data-urlencode "text=${text}" \
    --data-urlencode "disable_web_page_preview=true" >/dev/null 2>>"$LOG" \
    || log "tg: alert send failed (non-fatal)"
}

# 알림 문안 생성. $1=라벨(신규|누적), $2.. = "stage|source|reason" 항목들.
# 문안 규약은 health-report.py 와 동일(번호식·무이모지·줄끝 표식) — 같은 방에 섞여 오므로.
alert_msg(){
  local label="$1"; shift
  local total=$# i=0 e stage rest src why hint msg
  msg="[파싱 실패] ${label} ${total}건 · $(hostname)
$(date '+%Y-%m-%d %H:%M KST')

1. 추출 실패"
  for e in "$@"; do
    i=$((i+1))
    if [ "$i" -gt "$ALERT_MAX" ]; then
      msg="${msg}
1-$((ALERT_MAX+1)). …외 $(( total - ALERT_MAX ))건 [x]"
      break
    fi
    stage="${e%%|*}"; rest="${e#*|}"; src="${rest%%|*}"; why="${rest#*|}"
    hint=""
    # hwp 는 조치가 정해져 있다 — 알림에 그 한 줄이 있으면 바로 손이 움직인다.
    [ "$stage" = hwp ] && hint=" → 한컴에서 hwpx 로 재저장하면 OWPML 직독 경로가 처리"
    msg="${msg}
1-${i}. $(basename "$src") [x]
      ${stage}: $(printf '%s' "$why" | cut -c1-90)${hint}
      ${src}"
  done
  printf '%s' "$msg"
}

# ── --alert-only: 현재 쌓인 마커를 훑어 재발송하고 종료 ──
if [ "$ALERT_ONLY" = 1 ]; then
  STANDING=()
  while IFS= read -r m; do
    [ -n "$m" ] || continue
    st="$(awk -F': ' '/^stage:/{print $2; exit}' "$m" 2>/dev/null)"
    sr="$(awk -F': ' '/^source:/{print $2; exit}' "$m" 2>/dev/null)"
    rn="$(awk -F': ' '/^reason:/{ $1=""; sub(/^ /,""); print; exit}' "$m" 2>/dev/null)"
    STANDING+=("${st:-?}|${sr:-$(dirname "$m")}|${rn:-(사유 미상)}")
  done < <(find "$SB_DATA/sources" -name .parse-error 2>/dev/null | sort)
  if [ "${#STANDING[@]}" -eq 0 ]; then
    # 0건도 **보낸다**. 물어본 사람에게 "지금 깨끗하다"가 답이다(침묵은 답이 아니다).
    tg_send "[파싱 실패] 누적 0건 · $(hostname)
$(date '+%Y-%m-%d %H:%M KST')

1. 추출 실패
1-1. 없음 [o]"
    log "tg: --alert-only — 누적 0건 알림 발송"
  else
    tg_send "$(alert_msg "누적" "${STANDING[@]}")"
    log "tg: --alert-only — 누적 ${#STANDING[@]}건 알림 발송"
  fi
  exit 0
fi

shopt -s nullglob globstar
n=0

# ── 스캔 범위: sources 전체 (2026-08-05 확대) ──────────────────────────────
# 예전엔 00_inbox 만 봤다. 그래서 PARA 로 분류돼 인박스를 떠난 자료는 파싱된 적이 없으면
# 영원히 파싱되지 않았다 — refine 이 같은 이유로 72건을 놓치고 있던 것과 **똑같은 구조 결함**의
# 추출 단계 판이다(2026-08-05 규명). refine 쪽만 고치면 짝이 안 맞아 no-extract 백로그가 남는다.
#
# ★ 확대의 대가는 크다: 확대 시점 실측 미파싱 704건(인박스 밖 699 — jpg 286·pdf 182·png 131…).
#   PDF 는 듀얼엔진(mineru 느림)이고 이미지는 OCR ~35초라 전부 갈면 십수 시간이며, PDF 파싱은
#   이어서 refine 의 diverge(비전검증=토큰) 대기열로 흘러든다. 그래서 **한 런당 상한**을 둔다 —
#   드레인이 기계를 몇 시간씩 점유하지 않고 백로그를 며칠에 걸쳐 조금씩 소화하게.
# ★ 인박스 우선: 후보 목록을 00_inbox 먼저 내보낸다. 신규 유입이 백로그 뒤에 줄서지 않게.
SOURCES_ROOT="$SB_DATA/sources"
MAX_PER_RUN="${PARSER_DRAIN_MAX_PER_RUN:-5}"     # 0 = 무제한(백로그 몰아치기용 수동 실행)
bn=0                                             # 백로그(인박스 밖) 처리 수 — 캡은 이것만 센다

# ★ 캡은 **백로그에만** 건다. 인박스는 캡과 무관하게 끝까지 비운다 —
#   안 그러면 새로 들어온 자료가 수백 건 백로그 뒤에 줄서서 며칠씩 파싱을 못 받는다
#   (첫 실측: 캡 5 를 hwp 백로그가 다 먹어 pdf·이미지 루프가 통째로 밀렸다).
#   candidates() 가 인박스분을 먼저 내보내므로, 백로그 구간에 들어선 뒤의 break 는 안전하다.
is_inbox(){ case "$1" in "$INBOX"/*) return 0;; *) return 1;; esac; }
cap_reached(){ [ "$MAX_PER_RUN" -gt 0 ] && [ "$bn" -ge "$MAX_PER_RUN" ]; }
# 백로그 항목에서만 캡을 검사·중단. 인박스면 무조건 통과.
backlog_stop(){ is_inbox "$1" && return 1; cap_reached; }
count_one(){ n=$((n+1)); }

# ★ 캡은 **시도**를 센다(성공이 아니라). 성공만 세면 실패가 캡을 소비하지 않아, 깨진 파일이
#   많을수록 런이 무한정 길어진다 — 확대 첫날 실측: 메리츠화재 PDF 등에서 FAIL 이 줄줄이
#   나면서 런이 몇 시간째 안 끝났다.
attempt_one(){ is_inbox "$1" || bn=$((bn+1)); }

# ★ 이미 실패한 파일은 다음 런에서 건너뛴다. 예전 멱등 검사는 성공 산출물(diff/docling/ocr.json)만
#   봐서, 실패 파일은 **매 런마다 영원히 재시도**됐다(로그에 FAIL 2200여 줄이 쌓인 이유).
#   인박스만 보던 시절엔 몇 건이라 티가 안 났지만 범위를 넓히면 캡을 통째로 먹는다.
#   재시도는 명시적으로: PARSER_DRAIN_RETRY_ERRORS=1 (파서 개선 후 일괄 재시도용).
ferr=0
skip_failed(){ [ -e "$1/.parse-error" ] && [ "${PARSER_DRAIN_RETRY_ERRORS:-0}" != 1 ]; }

# ── 방대 reference 게이트 (2026-08-07 신설) ────────────────────────────────────
#
# 1,400페이지짜리 수가집·초록집 같은 문서는 **풀파싱하지 않는다.** vault 운영 매뉴얼의
# skipped-bulk 규칙(≥100p 는 풀텍스트 대신 목차·페이지 인덱스 + on-demand `Read pages:`)이
# 이미 그렇게 정하고 있고, `brainify.py _is_bulk()` 에도 같은 게이트가 구현돼 있다.
#
# 그런데 추출 단계에는 그 게이트가 없어서, brainify 가 "방대해서 자동 파싱 제외" 라고 판단할
# 문서를 parser-drain 이 먼저 30분씩 갈고 있었다(실측: 2026년판 1,430p 가 27분 30초, 2025년판
# 1,472p 는 900초 상한에 두 번 걸려 실패). GPU·시간을 쓰고도 산출물은 brainify 가 안 쓴다.
#
# 판정 기준은 brainify 와 **똑같이** 맞춘다 — 두 단계가 다른 잣대를 쓰면 그 자체가 버그다.
#   (페이지≥BULK_PAGES) OR (크기≥BULK_MB) OR (이름패턴 AND 규모 하한)
# 건너뛴 것은 `.parse-skipped` 로 표시한다. **`.parse-error` 가 아니다** — 고장이 아니라 정책이고,
# 오류 집계를 오염시키면 안 된다.
#
# ★ 이름패턴에 규모 하한을 붙인 이유 (2026-08-07 개정). 초판은 이름패턴 단독으로 발동했다.
#   그래서 `AOFNMB Series of Books 관련 Korea chapter 저자 추천.pdf` — **94KB·5페이지** 문서가
#   파일명의 "Books" 하나로 방대 reference 취급돼 제외됐다. 게이트의 취지는 1,400페이지짜리를
#   GPU 에서 빼는 것이지 제목에 book 이 든 짧은 문서를 버리는 게 아니다. 이름은 *힌트*일 뿐이고
#   방대함의 근거는 규모여야 한다 — 그래서 이름패턴은 이제 **하한을 넘긴 문서에만** 적용되고,
#   하한을 명확히 넘는 문서는 이름과 무관하게 걸린다(이름패턴은 경계선 구간을 낮춰줄 뿐).
BULK_PAGES="${PARSER_DRAIN_BULK_PAGES:-100}"
BULK_MB="${PARSER_DRAIN_BULK_MB:-20}"
# 이름패턴이 맞을 때 적용하는 완화 하한 — 이름이 방대함을 시사하므로 문턱을 낮춰 잡는다.
BULK_NAME_PAGES="${PARSER_DRAIN_BULK_NAME_PAGES:-40}"
BULK_NAME_MB="${PARSER_DRAIN_BULK_NAME_MB:-8}"
BULK_NAME_RE="${PARSER_DRAIN_BULK_NAME:-초록집|자료집|proceedings|abstract|논문집|카탈로그|catalog|book}"

is_bulk(){   # $1=파일. 방대하면 사유를 stdout 에 내고 0, 아니면 1
  local f="$1" base pg mb named=0 hit=""
  base="$(basename "$f")"
  if printf '%s' "$base" | grep -qiE "$BULK_NAME_RE"; then
    named=1; hit="$(printf '%s' "$base" | grep -oiE "$BULK_NAME_RE" | head -1)"
  fi
  mb=$(( $(stat -c%s "$f" 2>/dev/null || echo 0) / 1048576 ))
  pg=""
  case "${f##*.}" in
    pdf|PDF) pg="$(pdfinfo "$f" 2>/dev/null | awk '/^Pages:/{print $2; exit}')" ;;
  esac
  if [ -n "$pg" ]; then
    [ "$pg" -ge "$BULK_PAGES" ] && { printf '%sp≥%sp' "$pg" "$BULK_PAGES"; return 0; }
    [ "$named" = 1 ] && [ "$pg" -ge "$BULK_NAME_PAGES" ] && {
      printf '이름패턴(%s)+%sp≥%sp' "$hit" "$pg" "$BULK_NAME_PAGES"; return 0; }
  else
    [ "$mb" -ge "$BULK_MB" ] && { printf '%sMB≥%sMB(페이지 미상)' "$mb" "$BULK_MB"; return 0; }
    [ "$named" = 1 ] && [ "$mb" -ge "$BULK_NAME_MB" ] && {
      printf '이름패턴(%s)+%sMB≥%sMB(페이지 미상)' "$hit" "$mb" "$BULK_NAME_MB"; return 0; }
  fi
  return 1
}

nbulk=0
mark_bulk(){   # $1=_parse dir  $2=원본  $3=사유
  mkdir -p "$1" 2>/dev/null || true
  printf 'ts: %s\nhost: %s\nsource: %s\nreason: 방대 reference — 자동 파싱 제외 (%s)\nhow: 풀텍스트 대신 목차·페이지 인덱스 + 필요 시 Read pages:\npolicy: vault CLAUDE.md skipped-bulk / brainify _is_bulk\n' \
    "$(date -Is)" "$(hostname)" "$2" "$3" >"$1/.parse-skipped" 2>/dev/null || true
}
skip_bulk(){ [ -e "$1/.parse-skipped" ] && [ "${PARSER_DRAIN_FORCE_BULK:-0}" != 1 ]; }

# 후보 경로 나열. $@ = 확장자들. 인박스분을 먼저, 그다음 sources 전체(중복은 dedup).
# 파싱 산출물 내부(`*_parse/`)는 여기서 일괄 제외 — mineru 가 뽑아 둔 figure 이미지를 다시
# OCR 하는 무한 증식을 막는다(예전엔 이미지 루프에만 있던 가드를 전 루프로 올림).
# `00_inbox/_hold/` 도 제외 — Dr. Ben 이 손으로 떨어뜨리고 **지시할 때까지 기다리는** 대기실이다.
# 파싱은 무해해 보이지만 _parse 산출물이 먼저 생기면 대기실이 "이미 처리 중"처럼 보이고,
# 무엇보다 복사가 끝나기 전 파일을 집어 잘린 사본을 파싱할 수 있다. 손 자료는 지시 후에만 만진다.
# ★ 확장자는 대소문자 무관 (2026-09-10): KIRAMS 원내 캡처·폰 스크린샷은 `.PNG`·`.JPG` 로 오는데
#   소문자 glob 만 돌아 영원히 미파싱 → brainify 가 pending-ocr stub 을 만들고 텔레그램이 매 틱
#   "파싱오류 stub" 을 울렸다(실측: 2026-09-08_발명신고서_스캔 / 발명신고서.PNG).
# ★ 편집기 임시·잠금 파일 제외 (2026-09-10): Word 소유자 파일 `~$*.docx`, LibreOffice `.~lock.*#`,
#   macOS `._*`. \\wsl.localhost 로 vault 문서를 열면 옆에 생기고 docling 이 "not valid" FAIL →
#   .parse-error + 고아 `_parse/` 가 남는다(실측 2026-08-13 KSNM docx, 2026-09-10 TOR docx).
candidates(){
  local ext f e
  {
    for ext in "$@"; do for e in "$ext" "${ext^^}"; do
      for f in "$INBOX"/**/*."$e"; do printf '%s\n' "$f"; done
    done; done
    for ext in "$@"; do for e in "$ext" "${ext^^}"; do
      for f in "$SOURCES_ROOT"/**/*."$e"; do printf '%s\n' "$f"; done
    done; done
  } | grep -v '_parse/' | grep -v "^${INBOX}/_hold/" \
    | grep -v -E '/(~\$|\.~lock\.|\._)[^/]*$' | awk '!seen[$0]++'
}

# ── HWP/HWPX: 호스트-측 추출(컨테이너 우회) → refined.md 직접 생산 ──
# 근거: 컨테이너 soffice+H2Orestart 경로는 headless user-프로필 미초기화로 실패 잦고
#       hwpx 표를 버린다. 호스트엔 검증된 우월 경로(OWPML 직독 + soffice→docx→pandoc)가 있다.
#       HWP 는 단일소스(mineru N/A·diff 불가)라 refine 이 no-op → 추출=refine 한 번에, refined.md 직접.
#       brainify `_refined()` 가 이 refined.md 를 소비(컨테이너 안 탐). 멱등: refined.md 있으면 skip.
HWP_REFINE="$REPO/docker/parser-drain/hwp_refine.py"
XLSX_REFINE="$REPO/docker/parser-drain/xlsx_refine.py"   # docling 실패 시 xlsx 폴백
while IFS= read -r f; do
  backlog_stop "$f" && { log "cap($MAX_PER_RUN) 도달 — hwp 백로그 중단"; break; }
  # 후보 목록은 런 시작에 한 번 만들어진다 — 그 사이 brainify·prune 이 원본을 옮기거나
  # 지웠을 수 있다. 확인 없이 진행하면 아래 `mkdir -p "$out"` 가 **사라진 폴더를 되살려**
  # 빈 `_parse/` + `.parse-error` 껍데기를 남긴다(2026-08-06 실측: prune 으로 지운 인박스
  # 폴더 2개가 2분 만에 유령으로 부활). 인박스 적체 숫자를 오염시키는 유령의 출처였다.
  [ -f "$f" ] || { log "원본 사라짐(다른 단계가 이동·삭제) — skip: $f"; continue; }
  out="${f}_parse"
  [ -s "$out/refined.md" ] && continue           # 멱등
  # ★ .parse-skipped 는 **전 루프가 존중해야 한다.** PDF 루프에만 넣었더니, hwpx 로 대체
  #   처리해 skipped 로 표시한 hwp 를 이 루프가 무시하고 재시도해 실패 마커를 되살렸다
  #   (2026-08-07 실측). 표식은 형식이 아니라 *결정*이므로 형식별로 달리 볼 이유가 없다.
  skip_bulk "$out" && { nbulk=$((nbulk+1)); continue; }
  if bulkwhy="$(is_bulk "$f")"; then
    clear_error "$out"; log "skip(bulk): $f — $bulkwhy"; mark_bulk "$out" "$f" "$bulkwhy"
    nbulk=$((nbulk+1)); continue
  fi
  skip_failed "$out" && { ferr=$((ferr+1)); continue; }
  log "parse(hwp,host): $f"; attempt_one "$f"
  if python3 "$HWP_REFINE" "$f" >>"$LOG" 2>&1; then
    log "ok(hwp,host): $f"; clear_error "$out"; count_one "$f"
  else
    # hwp_refine 이 마커를 쓰지만 사유가 없다 → 로그 꼬리를 사유로 얹어 덮어쓴다.
    LAST_ERR="$(tail -3 "$LOG" | tr "\n" " " | tail -c 300)"
    log "FAIL hwp(host): $f"; mark_error "$out" hwp "$f"
  fi
done < <(candidates hwp hwpx)

# ── XLS(구형 엑셀): 호스트-측 stdlib 직독 ──
# 근거(2026-08-07 실측): .xls 를 여는 다른 경로가 전부 막혀 있다. docling 은 .xls 를 입력으로
#   받지 않고, 호스트 soffice 는 `no export filter`(libreoffice-calc 미설치 — writer·math 만
#   깔려 있어 hwp→pandoc 만 살아 있다), 컨테이너엔 soffice 자체가 없다. apt 로 calc 를 깔면
#   kimbi 만 되고 ai4lt·컨테이너는 조용히 실패하는 비대칭이 생겨, stdlib BIFF 직독으로 간다.
#   확장자가 .xls 여도 실제는 HTML 인 관공서 산출물이 있어 xls_refine 이 매직바이트로 가른다.
XLS_REFINE="$REPO/docker/parser-drain/xls_refine.py"
while IFS= read -r f; do
  backlog_stop "$f" && { log "cap($MAX_PER_RUN) 도달 — xls 백로그 중단"; break; }
  [ -f "$f" ] || { log "원본 사라짐(다른 단계가 이동·삭제) — skip: $f"; continue; }
  out="${f}_parse"
  [ -s "$out/refined.md" ] && continue           # 멱등
  skip_bulk "$out" && { nbulk=$((nbulk+1)); continue; }
  if bulkwhy="$(is_bulk "$f")"; then
    clear_error "$out"; log "skip(bulk): $f — $bulkwhy"; mark_bulk "$out" "$f" "$bulkwhy"
    nbulk=$((nbulk+1)); continue
  fi
  skip_failed "$out" && { ferr=$((ferr+1)); continue; }
  log "parse(xls,host): $f"; attempt_one "$f"
  if python3 "$XLS_REFINE" "$f" >>"$LOG" 2>&1; then
    log "ok(xls,host): $f"; clear_error "$out"; count_one "$f"
  else
    LAST_ERR="$(tail -3 "$LOG" | tr "\n" " " | tail -c 300)"
    log "FAIL xls(host): $f"; mark_error "$out" xls "$f"
  fi
done < <(candidates xls)

# ── PDF·docx·xlsx: 컨테이너(2nd-brain-parser) 경로 ──
while IFS= read -r f; do
  backlog_stop "$f" && { log "cap($MAX_PER_RUN) 도달 — pdf/docx/xlsx 백로그 중단"; break; }
  # 후보 목록은 런 시작에 한 번 만들어진다 — 그 사이 brainify·prune 이 원본을 옮기거나
  # 지웠을 수 있다. 확인 없이 진행하면 아래 `mkdir -p "$out"` 가 **사라진 폴더를 되살려**
  # 빈 `_parse/` + `.parse-error` 껍데기를 남긴다(2026-08-06 실측: prune 으로 지운 인박스
  # 폴더 2개가 2분 만에 유령으로 부활). 인박스 적체 숫자를 오염시키는 유령의 출처였다.
  [ -f "$f" ] || { log "원본 사라짐(다른 단계가 이동·삭제) — skip: $f"; continue; }
  out="${f}_parse"
  ext="${f##*.}"; ext="${ext,,}"
  cpath="${f/#$SB_DATA/$CMNT}"          # host→컨테이너 입력 경로
  cout="${out/#$SB_DATA/$CMNT}"         # host→컨테이너 _parse 경로

  # 멱등: PDF=diff.json, 비-PDF=docling.json 있으면 완료로 보고 skip
  if [ "$ext" = pdf ]; then [ -s "$out/diff.json" ] && continue
  else [ -s "$out/docling.json" ] || [ -s "$out/refined.md" ] && continue; fi
  # ★ 방대 게이트가 실패 게이트보다 **먼저** 온다. 순서가 반대면, 과거에 타임아웃으로 실패해
  #   .parse-error 가 붙은 방대 파일은 skip_failed 에서 걸러져 bulk 판정에 도달조차 못 한다
  #   (실측: 1,472p 수가집이 그래서 skip-bulk 0 으로 나왔다). 정책이 오류 상태보다 우선이다.
  skip_bulk "$out" && { nbulk=$((nbulk+1)); continue; }
  if bulkwhy="$(is_bulk "$f")"; then
    # 파싱을 시도하지 않기로 한 이상 과거의 실패 마커는 의미가 없다 — 오류 집계에서 뺀다.
    clear_error "$out"
    log "skip(bulk): $f — $bulkwhy"; mark_bulk "$out" "$f" "$bulkwhy"; nbulk=$((nbulk+1)); continue
  fi
  skip_failed "$out" && { ferr=$((ferr+1)); continue; }
  mkdir -p "$out"
  log "parse($ext): $f"; attempt_one "$f"

  # docling (전 포맷; 이미 있으면 재사용)
  if [ ! -s "$out/docling.json" ]; then
    if ! run_to "$out/docling.json" parse-docling "$cpath"; then
      # ★ xlsx 는 stdlib 폴백이 있다. docling 이 멀쩡한 엑셀을 못 읽는 경우가 실재한다
      #   (2026-08-07 실측 2건: ZeroDivisionError / ConversionError — 둘 다 zip·시트·
      #   sharedStrings 정상이었다). 파일이 아니라 파서 한계이므로 여기서 끝내면 안 된다.
      if [ "$ext" = xlsx ] && [ -f "$XLSX_REFINE" ] && python3 "$XLSX_REFINE" "$f" >>"$LOG" 2>&1; then
        log "ok(xlsx-stdlib 폴백): $f"; clear_error "$out"; count_one "$f"; continue
      fi
      log "FAIL docling: $f — $LAST_ERR"; mark_error "$out" docling "$f"; continue
    fi
  fi

  if [ "$ext" != pdf ]; then
    log "ok(single non-PDF): $f"; clear_error "$out"; count_one "$f"; continue
  fi

  # PDF: mineru (재사용) + diff
  if [ ! -s "$out/mineru.json" ]; then
    run_to "$out/mineru.json" parse-mineru "$cpath" || log "WARN mineru 실패(docling-only): $f"
  fi
  if [ -s "$out/mineru.json" ] && [ ! -s "$out/diff.json" ]; then
    if run_to "$out/diff.json" diff "$cout/docling.json" "$cout/mineru.json"; then
      v=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1])).get('verdict','?'))" "$out/diff.json" 2>/dev/null || echo '?')
      log "ok(dual,verdict=$v): $f"; clear_error "$out"; count_one "$f"
    else
      log "WARN diff 실패(docling+mineru는 있음): $f"; clear_error "$out"; count_one "$f"
    fi
  else
    log "ok(docling-only, mineru 없음): $f"; clear_error "$out"; count_one "$f"
  fi
done < <(candidates pdf docx xlsx pptx)

# ── 이미지: parse-ocr 단일 → ocr.json (전략 §이미지 OCR — device-adaptive) ──
# docling/mineru 대신 OCR. ⚠️ _parse/ 하위(mineru 가 추출한 figure 이미지)는 제외 —
# 안 그러면 추출 figure 를 재-OCR 하는 무한 증식. 멱등: ocr.json 있으면 skip.
while IFS= read -r f; do
  backlog_stop "$f" && { log "cap($MAX_PER_RUN) 도달 — 이미지 백로그 중단"; break; }
  # 후보 목록은 런 시작에 한 번 만들어진다 — 그 사이 brainify·prune 이 원본을 옮기거나
  # 지웠을 수 있다. 확인 없이 진행하면 아래 `mkdir -p "$out"` 가 **사라진 폴더를 되살려**
  # 빈 `_parse/` + `.parse-error` 껍데기를 남긴다(2026-08-06 실측: prune 으로 지운 인박스
  # 폴더 2개가 2분 만에 유령으로 부활). 인박스 적체 숫자를 오염시키는 유령의 출처였다.
  [ -f "$f" ] || { log "원본 사라짐(다른 단계가 이동·삭제) — skip: $f"; continue; }
  out="${f}_parse"
  ext="${f##*.}"; ext="${ext,,}"
  cpath="${f/#$SB_DATA/$CMNT}"               # host→컨테이너 입력 경로
  [ -s "$out/ocr.json" ] && continue         # 멱등
  # 수동으로 보류 표시한 이미지도 존중. (이름패턴 bulk 는 사진에 오탐이라 미적용)
  skip_bulk "$out" && { nbulk=$((nbulk+1)); continue; }
  skip_failed "$out" && { ferr=$((ferr+1)); continue; }
  mkdir -p "$out"
  log "parse(ocr:$ext): $f"; attempt_one "$f"
  if run_to "$out/ocr.json" parse-ocr "$cpath"; then
    log "ok(ocr): $f"; clear_error "$out"; count_one "$f"
  else
    log "FAIL ocr: $f — $LAST_ERR"; mark_error "$out" ocr "$f"
  fi
done < <(candidates png jpg jpeg webp tiff)

# ── 오디오: 폰 ingress 복사 + 호스트-측 전사(faster-whisper) → refined.md 직접 ──
# ⚠️ 이 루프만 **인박스 전용으로 남긴다**(위 확대에서 제외). 오디오는 선별 게이트가 걸린
# 자산이라(사적 녹음의 무인 PARA 편입 금지, 2026-07-13) 범위를 넓히면 그 게이트가 무의미해진다.
# 폰(SyncThing receive-only, 볼트 밖) → inbox 복사(ledger 멱등) → 로컬 GPU 전사.
# receive-only 폴더에서 move 금지(SyncThing 이 복원함) → copy + ledger(이름:크기).
# whisper venv 부재 머신(예: GPU 점유 노트북)은 루프째 skip — device-adaptive,
# 머신-specific 하드코딩 없음. 클라우드 STT 배제(이미지 OCR 과 동일 원칙).
AUDIO_VENV="${AUDIO_VENV:-$HOME/.venvs/whisper}"
AUDIO_INGRESS="${AUDIO_INGRESS:-$HOME/phone-ingress/voice}"
AUDIO_REFINE="$REPO/docker/parser-drain/audio_refine.py"
AUDIO_LEDGER="${AUDIO_LEDGER:-$HOME/.local/state/audio-ingress.ledger}"

MEET_INGRESS="$REPO/docker/parser-drain/drive_meet_ingress.py"

if [ -x "$AUDIO_VENV/bin/python" ]; then
  # ⓪ Drive ingress — Google Meet 녹화(mp4) → inbox. DRIVE_ACCOUNT 미설정 머신은
  #    스크립트가 스스로 skip(오디오 venv 어댑터와 같은 device-adaptive 규약).
  if [ -n "${DRIVE_ACCOUNT:-}" ] && [ -f "$MEET_INGRESS" ]; then
    if python3 "$MEET_INGRESS" >>"$LOG" 2>&1; then
      log "ingress(meet): ok"
    else
      log "WARN meet ingress 일부 실패 (로그 참조)"
    fi
  fi

  # ① ingress → inbox 복사 (brainify 가 inbox 밖으로 옮겨도 ledger 가 재복사 방지)
  if [ -d "$AUDIO_INGRESS" ]; then
    touch "$AUDIO_LEDGER"
    for f in "$AUDIO_INGRESS"/**/*.m4a "$AUDIO_INGRESS"/**/*.mp3 \
             "$AUDIO_INGRESS"/**/*.wav "$AUDIO_INGRESS"/**/*.ogg \
             "$AUDIO_INGRESS"/**/*.opus "$AUDIO_INGRESS"/**/*.aac \
             "$AUDIO_INGRESS"/**/*.amr; do
      base="$(basename "$f")"; key="$base:$(stat -c%s "$f")"
      if ! grep -qxF "$key" "$AUDIO_LEDGER"; then
        dest="$INBOX/${base// /_}"                 # 공백→_ (파일명 규칙)
        if [ ! -e "$dest" ]; then cp "$f" "$dest"; fi
        echo "$key" >>"$AUDIO_LEDGER"
        log "ingress(audio): $base"
      fi
    done
  fi

  # ② inbox 전사 — 미처리분 모아 1회 호출(모델 1회 로드). 멱등: refined.md 있으면 skip.
  pending=()
  # 비디오(mp4·mkv·webm)도 같은 레인 — faster-whisper 가 PyAV 로 오디오 트랙을
  # 직접 디코드하므로 별도 추출(ffmpeg) 불필요. Meet 녹화가 여기로 들어온다.
  for f in "$INBOX"/**/*.m4a "$INBOX"/**/*.mp3 "$INBOX"/**/*.wav \
           "$INBOX"/**/*.ogg "$INBOX"/**/*.opus "$INBOX"/**/*.aac \
           "$INBOX"/**/*.amr "$INBOX"/**/*.mp4 "$INBOX"/**/*.mkv \
           "$INBOX"/**/*.webm; do
    [[ "$f" == *_parse/* ]] && continue
    [ -s "${f}_parse/refined.md" ] && continue
    pending+=("$f")
  done
  if [ "${#pending[@]}" -gt 0 ]; then
    log "parse(audio,host): ${#pending[@]} file(s)"
    if timeout $((ENGINE_TIMEOUT * ${#pending[@]})) \
         "$AUDIO_VENV/bin/python" "$AUDIO_REFINE" "${pending[@]}" >>"$LOG" 2>&1; then
      n=$((n + ${#pending[@]}))
      log "ok(audio): ${#pending[@]} file(s)"
    else
      log "WARN audio 일부/전부 실패 (개별 .parse-error 참조)"
    fi
  fi
fi

# 실패로 건너뛴 건수를 반드시 남긴다 — 조용히 빠지면 "백로그가 다 끝났다"로 오독된다.
[ "$ferr" -gt 0 ] && log "skip(.parse-error): ${ferr}건 — 재시도는 PARSER_DRAIN_RETRY_ERRORS=1"
# ── 신규 실패 즉시 알림 ──
if [ "${#NEWFAIL[@]}" -gt 0 ]; then
  tg_send "$(alert_msg "신규" "${NEWFAIL[@]}")"
  log "tg: 신규 실패 ${#NEWFAIL[@]}건 알림 발송"
fi

[ "$nbulk" -gt 0 ] && log "skip(bulk): ${nbulk}건 — 방대 reference, 강제 파싱은 PARSER_DRAIN_FORCE_BULK=1"
log "drain done ($n processed, backlog ${bn}/${MAX_PER_RUN}, skip-failed ${ferr}, skip-bulk ${nbulk})"
