# nobu-ios — 実機まわりの手順を1コマンドに畳んだもの
#
# 何のためか:
#   無料の Apple Personal Team で署名したプロビジョニングプロファイルは **7日で失効**し、
#   失効するとアプリが起動できなくなる（本棚のデータはサーバー側なので無事）。
#   その復旧が `xcodegen generate` → `xcodebuild` → `devicectl install` の3手だったので、
#   `make resign` の1手にした（health-sync・michinori と同じ流儀）。
#
# よく使うのは:
#   make resign         7日ごとの再署名。iPhone を Mac に繋いでから叩く
#   make check          実機なしでコンパイルだけ確かめる（署名しない・繋がなくてよい）
#   make sim            iOS シミュレータ向けにビルドだけ通す（署名も実機も要らない）
#   make import-access  Cloudflare Access のサービストークンを実機へ流し込む
#   make launch         実機で起動してコンソールを見る（クラッシュ調査）
#   make devices        繋がっている端末の一覧（DEVICE の UUID を確かめたいとき）
#
# ⚠️ 注意
#   - `*.xcodeproj` は生成物でコミットしていない。**必ず `xcodegen generate` が先**
#     （`brew install xcodegen` が要る）。各ターゲットの先頭で毎回走らせている
#   - `devicectl` は**先頭がハイフンの引数を自分のものと解釈する**ので、アプリへ引数を渡すときは
#     その前に `--` が要る
#   - `-derivedDataPath build` は**実機インストール用の成果物**。`make check` / `make sim` は
#     これを壊さないよう別の場所を使い、終わったら消している
#   - 初回インストール時だけ、実機で開発元を信頼する操作が要る
#     （設定 → 一般 → VPN とデバイス管理 → Apple Development: kechiiiiin@gmail.com → 信頼）
#   - カメラの許可は**ネイティブなので一度きり**（Web 版は開くたびに訊かれていた）

DEVICE  = 8EAC2623-47F0-58AC-9DEF-8DD9AE4D6E55
BUNDLE  = jp.kechiiiiin.nobu
PROJECT = nobu-ios.xcodeproj
SCHEME  = NoBu
APP     = build/Build/Products/Debug-iphoneos/nobu.app

.PHONY: help resign generate build install launch import-access check sim icon devices clean

help:
	@echo "resign          再署名（generate → build → install）。7日ごと・iPhone を繋いでから"
	@echo "check           実機なしでコンパイルだけ確認（署名なし）"
	@echo "sim             シミュレータ向けにビルドだけ通す"
	@echo "import-access   Cloudflare Access のサービストークンを実機へ流し込む（次の起動で Keychain へ）"
	@echo "launch          実機で起動してコンソールを見る"
	@echo "icon            アプリアイコン PNG を描き直す"
	@echo "devices         繋がっている端末の一覧"
	@echo "clean           build/ build-check/ build-sim/ と生成した .xcodeproj を消す"

## 7日ごとの再署名。これ1本で generate → build → install まで通る
resign: generate build install
	@echo "✅ 再署名して実機に入れた。次の失効まで7日"

generate:
	xcodegen generate

## 実機向けにビルドして署名する（プロファイルの更新も任せる）
build:
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) \
	  -destination "id=$(DEVICE)" -configuration Debug \
	  -derivedDataPath build -allowProvisioningUpdates build

install:
	xcrun devicectl device install app --device $(DEVICE) $(APP)

## 実機で起動してコンソールを見る（クラッシュしていないかの確認）
launch:
	xcrun devicectl device process launch --device $(DEVICE) --console \
	  --terminate-existing $(BUNDLE)

## Cloudflare Access のサービストークンを実機へ流し込む
## アプリのコンテナの tmp/ にファイルとして置くだけ。**次にアプリが起動したとき**（手で開いても可）
## LaunchConfig が Keychain へ移してファイルを消す。値は表示もしないし起動引数にも載せない。
## ⚠️ `copy to` のユーザー指定は --user（`info files` の --username とは違う）
import-access:
	@test -s ~/.config/nobu/access-client-id && test -s ~/.config/nobu/access-client-secret \
	  || { echo "~/.config/nobu/access-client-{id,secret} が無い"; exit 1; }
	xcrun devicectl device copy to --device $(DEVICE) \
	  --domain-type appDataContainer --domain-identifier $(BUNDLE) --user mobile \
	  --source ~/.config/nobu/access-client-id --destination tmp/nobu-import-access-client-id
	xcrun devicectl device copy to --device $(DEVICE) \
	  --domain-type appDataContainer --domain-identifier $(BUNDLE) --user mobile \
	  --source ~/.config/nobu/access-client-secret --destination tmp/nobu-import-access-client-secret
	@echo "✅ 置いた。iPhone で NoBu を開く（または make launch）と Keychain へ取り込まれ、ファイルは消える"

## 実機を繋がずにコンパイルだけ確かめる。署名もしないので手ぶらで叩ける
check: generate
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) \
	  -destination 'generic/platform=iOS' -configuration Debug \
	  -derivedDataPath build-check CODE_SIGNING_ALLOWED=NO build
	@rm -rf build-check
	@echo "✅ コンパイルは通る"

## シミュレータ向けのビルド（実機が手元に無いときの確認用。カメラは動かない）
sim: generate
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) \
	  -destination 'generic/platform=iOS Simulator' -configuration Debug \
	  -derivedDataPath build-sim build
	@rm -rf build-sim
	@echo "✅ シミュレータ向けのビルドは通る"

icon:
	python3 scripts/gen-icon.py

devices:
	xcrun devicectl list devices

clean:
	rm -rf build build-check build-sim $(PROJECT)
