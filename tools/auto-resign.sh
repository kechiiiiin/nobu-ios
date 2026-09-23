#!/bin/bash
#
# nobu — 無線での自動再署名（launchd から呼ばれる）
#
# 無料 Personal Team のプロファイルは7日で失効し、失効するとアプリが起動できなくなる
# （本棚のデータはサーバー側なので無事。再署名して開けば元通り）。iPhone は自宅 Wi-Fi 越しに devicectl から
# 見えている（transportType: localNetwork）ので、ケーブルを挿さずに `make resign` が通る。
# それを一日置きにまわして手作業をゼロにするのがこのスクリプト。
#
# ⚠️ ここが肝 — 単に `make resign` を叩くだけでは期限が伸びないことがある。
#   Xcode は手元にキャッシュしたプロビジョニングプロファイルが**まだ失効していなければ
#   それを使い回す**ので、再署名しても埋め込まれるのは古いプロファイルのまま。
#   2026-09-12 に michinori で実際に踏んだ（残り1時間半のプロファイルが更新されなかった）。
#   → 期限が近いときは**キャッシュを消してから**ビルドし、Xcode に取り直させる。
#   → さらにビルド後、埋め込まれた期限が本当に伸びたかを検算して、伸びていなければ失敗扱いにする。
#
# health-sync（4:00）・michinori（4:20）にも同じ仕組みが入っている。nobu は 4:40 でビルドが重ならない。
#
# ログ: ~/Library/Logs/nobu-resign.log

set -uo pipefail

# launchd の PATH は最小限。homebrew（xcodegen）と Xcode のツールを明示的に足す
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

REPO="$HOME/work/nobu-ios"
BUNDLE="jp.kechiiiiin.nobu"
DEVICE="8EAC2623-47F0-58AC-9DEF-8DD9AE4D6E55"
APP="$REPO/build/Build/Products/Debug-iphoneos/nobu.app"
PROFILE_DIR="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
LOG="$HOME/Library/Logs/nobu-resign.log"

# キャッシュを捨てて取り直す閾値（日）。7日のうち残りがこれを切ったら更新しにいく
RENEW_WITHIN_DAYS="${RENEW_WITHIN_DAYS:-3}"   # 手で今すぐ取り直したいときは RENEW_WITHIN_DAYS=8 で叩く

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >>"$LOG"; }
# 失敗は Mac の通知に加えて Discord（再署名の失敗通知用チャンネル）にも送る。朝の Mac 通知は見落とすため
# URL は ~/.config/ios-resign/discord-webhook（600・リポジトリには入れない・michinori/health-sync と共有）
# launchd は iCloud の vault を読めないのでここに置いてある
WEBHOOK_FILE="$HOME/.config/ios-resign/discord-webhook"
notify() {
  /usr/bin/osascript -e "display notification \"$2\" with title \"$1\"" >/dev/null 2>&1
  [ -f "$WEBHOOK_FILE" ] || return 0
  local payload
  payload=$(T="$1" B="$2" /usr/bin/python3 -c 'import json,os; print(json.dumps({"content": "**"+os.environ["T"]+"**\n"+os.environ["B"], "username": "ヘスティア"}))')
  curl -s -o /dev/null -m 15 -H 'Content-Type: application/json' -d "$payload" "$(cat "$WEBHOOK_FILE")" || log "Discord への通知に失敗"
}

# プロファイルの失効日を epoch 秒で返す（読めなければ空）
expiry_epoch() {
  local d
  d=$(security cms -D -i "$1" 2>/dev/null | plutil -extract ExpirationDate raw -o - - 2>/dev/null) || return 0
  [ -n "$d" ] || return 0
  TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%SZ" "$d" +%s 2>/dev/null
}

log "--- 自動再署名を開始"

# 1. 端末が Wi-Fi 越しに見えているか（外出中・電源断ならここで諦める）
#    ⚠️ 直前に別のインストールが走った直後などは一瞬 available から外れる。
#       3回まで様子を見てから諦める
seen=0
for attempt in 1 2 3; do
  # ⚠️ Xcode 27 から表の Identifier 欄が CoreDevice ID ではなく UDID になり、表への grep が常に外れて
  #    「端末が見えない」で黙って見送り続ける事例があった。JSON の identifier で判定する
  j=$(mktemp); xcrun devicectl list devices --json-output "$j" >/dev/null 2>&1
  if /usr/bin/python3 -c 'import json,sys
d=[x for x in json.load(open(sys.argv[1]))["result"]["devices"] if x.get("identifier")==sys.argv[2]]
c=d[0].get("connectionProperties",{}) if d else {}
sys.exit(0 if d and c.get("pairingState")=="paired" and c.get("transportType") else 1)' "$j" "$DEVICE" 2>/dev/null; then rm -f "$j"; seen=1; break; fi
  rm -f "$j"
  [ "$attempt" -lt 3 ] && sleep 30
done
if [ "$seen" -eq 0 ]; then
  log "端末が見えない（外出中か電源断）。今回は見送る"
  exit 0   # 失敗ではないので通知しない。次の実行機会に任せる
fi

cd "$REPO" || { log "リポジトリが無い: $REPO"; notify "nobu 再署名に失敗" "リポジトリが見つかりません"; exit 1; }

# 2. 期限が近いキャッシュ済みプロファイルを消す（Xcode に取り直させるため）
now=$(date +%s)
threshold=$(( now + RENEW_WITHIN_DAYS * 86400 ))
shopt -s nullglob
for f in "$PROFILE_DIR"/*.mobileprovision; do
  name=$(security cms -D -i "$f" 2>/dev/null | plutil -extract Name raw -o - - 2>/dev/null)
  case "$name" in *"$BUNDLE"*) ;; *) continue ;; esac
  exp=$(expiry_epoch "$f")
  if [ -n "$exp" ] && [ "$exp" -lt "$threshold" ]; then
    log "期限が近いプロファイルを削除して取り直す（失効: $(date -r "$exp" '+%Y-%m-%d %H:%M')）"
    rm -f "$f"
  fi
done

# 3. 再署名（generate → build → install）
OUT=$(mktemp)
if ! make resign >"$OUT" 2>&1; then
  cat "$OUT" >>"$LOG"
  log "❌ make resign が失敗（詳細は直前のログ）"
  # 原因の1行目を本文に載せる（「No Accounts」なら Xcode → Settings → Accounts でサインインし直す）
  err=$(grep -m1 'error:' "$OUT" | sed -E 's/.*error: //' | cut -c1-200)
  rm -f "$OUT"
  notify "nobu 再署名に失敗" "${err:-原因はログを参照}
ログ: ~/Library/Logs/nobu-resign.log"
  exit 1
fi
cat "$OUT" >>"$LOG"; rm -f "$OUT"

# 4. 検算 — 埋め込まれた期限が本当に伸びたか。伸びていなければ静かな失敗なので鳴らす
exp=$(expiry_epoch "$APP/embedded.mobileprovision")
if [ -z "$exp" ]; then
  log "⚠️ 成功したが、埋め込みプロファイルの期限を読めなかった"
  exit 0
fi
left_days=$(( (exp - now) / 86400 ))
log "✅ 成功。失効: $(date -r "$exp" '+%Y-%m-%d %H:%M')（残り ${left_days}日）"
if [ "$left_days" -lt 2 ]; then
  notify "nobu の署名が更新されていない" "残り ${left_days}日。プロファイルが取り直せていません"
  exit 1
fi
exit 0
