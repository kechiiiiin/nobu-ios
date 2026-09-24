#!/bin/sh
# UI テスト（make uitest）が当てにしている本を、**ローカルの Worker** に用意する。
#
# ⚠️ 相手は 127.0.0.1:8787 だけ。本番（nobu.kechiiiiin.com）にも本番 D1 にも触らない。
# 先に別のタブで `cd ~/work/nobu && npm run dev` を上げておくこと（DEV_BYPASS_AUTH で素通りする）。
#
# 既にある本は足さない（何度叩いても増えない）。
set -eu

BASE=${NOBU_BASE_URL:-http://127.0.0.1:8787}

case "$BASE" in
  http://127.0.0.1:*|http://localhost:*) ;;
  *) echo "ローカル以外には流し込まない: $BASE" >&2; exit 1 ;;
esac

curl -sf -o /dev/null "$BASE/api/me" \
  || { echo "ローカルの Worker が動いていない（cd ~/work/nobu && npm run dev）" >&2; exit 1; }

add() {  # add <書名> <状態>
  if curl -sf "$BASE/api/books?status=$2" | grep -q "\"title\":\"$1\""; then
    echo "  すでにある: $1"
  else
    curl -sf -o /dev/null -X POST "$BASE/api/books" -H 'Content-Type: application/json' \
      -d "{\"manual\":{\"title\":\"$1\",\"author\":\"検査用\"},\"status\":\"$2\",\"via\":\"manual\"}"
    echo "  足した: $1（$2）"
  fi
}

echo "ローカルに UI テスト用の本を用意する（$BASE）"
add "検査・読んでる" reading
add "検査・買った"   bought
add "検査・気になる" want
add "検査・読了"     read
add "検査・保留"     paused
echo "✅ 用意できた"
