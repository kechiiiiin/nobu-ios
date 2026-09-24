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

mark_read() {  # mark_read <書名> <状態> <日>  その本の「読んだ日」にする（同じ日は二度押しても増えない）
  id=$(curl -sf "$BASE/api/books?status=$2" | python3 -c '
import json, sys
title = sys.argv[1]
body = json.load(sys.stdin)
books = body["books"] if isinstance(body, dict) else body
print(next(b["id"] for b in books if b["title"] == title))
' "$1")
  curl -sf -o /dev/null -X POST "$BASE/api/books/$id/days" -H 'Content-Type: application/json' -d "{\"on\":\"$3\"}"
}

echo "ローカルに UI テスト用の本を用意する（$BASE）"
add "検査・読んでる" reading
add "検査・買った"   bought
add "検査・気になる" want
add "検査・読了"     read
add "検査・保留"     paused
# 記録タブの「同じ日に複数冊読んだ」行（1行にまとまる）を出すため、3冊を同じ日に読んだことにする
for pair in "検査・読了 read" "検査・保留 paused" "検査・買った bought"; do
  set -- $pair
  mark_read "$1" "$2" 2026-09-22
done
echo "  読んだ日: 検査・読了／保留／買った を 2026-09-22 に"
echo "✅ 用意できた"
