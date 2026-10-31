#!/bin/bash
# 封存並匯出 Ad Hoc 的 .ipa（iPad／iPhone 都能裝，限開發者帳號登記過的裝置），
# 並放到 ../ios/rcw-month-ios.ipa、更新 ../ios/manifest.plist 的版本號。
#
# 在 MacBook 的「終端機」執行（SSH 進來的話鑰匙圈是鎖的、會簽章失敗）：
#   bash ~/Developer/rcw-month/ios-app/build-ipa.sh            # 只建置
#   bash ~/Developer/rcw-month/ios-app/build-ipa.sh --publish  # 建置後 git commit + push，安裝頁立刻有新版
# SSH 進來時改用：
#   osascript ~/Developer/rcw-month/ios-app/run-in-terminal.applescript "bash ~/Developer/rcw-month/ios-app/build-ipa.sh --publish"
#
# 需要：Xcode（已登入 Apple ID，Team 7BN6XJ59KP）、xcodegen（brew install xcodegen）
# 進度寫在 build/ipa.log，完成會留下 build/ipa.done（內容 ok 或 fail）
cd "$(dirname "$0")"
mkdir -p build
rm -f build/ipa.done
exec > >(tee build/ipa.log) 2>&1
set -o pipefail
fail() { echo "fail" > build/ipa.done; echo "❌ 建置失敗，請看 ios-app/build/ipa.log"; exit 1; }

XG=$(command -v xcodegen || echo /opt/homebrew/bin/xcodegen)
[ -x "$XG" ] || XG=/usr/local/bin/xcodegen
[ -x "$XG" ] || { echo "找不到 xcodegen，請先執行：brew install xcodegen"; fail; }
"$XG" generate --quiet || fail

rm -rf build/RcwMonth.xcarchive build/export
xcodebuild -project RcwMonth.xcodeproj -scheme RcwMonth -configuration Release \
  -destination 'generic/platform=iOS' -archivePath build/RcwMonth.xcarchive \
  -allowProvisioningUpdates archive | grep -E 'error|warning: .*sign|ARCHIVE' || fail
xcodebuild -exportArchive -archivePath build/RcwMonth.xcarchive -exportPath build/export \
  -exportOptionsPlist ExportOptions.plist -allowProvisioningUpdates || fail
IPA=$(ls build/export/*.ipa | head -1)
[ -f "$IPA" ] || fail

# 放到安裝頁資料夾，版本號跟著 project.yml
cp "$IPA" ../ios/rcw-month-ios.ipa
V=$(sed -n 's/.*MARKETING_VERSION: "\(.*\)".*/\1/p' project.yml | head -1)
sed -i '' "/<key>bundle-version<\/key>/{n;s|<string>.*</string>|<string>$V</string>|;}" ../ios/manifest.plist

# 列出這個 .ipa 可以安裝的裝置（UDID）
echo "可以安裝的裝置："
unzip -p ../ios/rcw-month-ios.ipa 'Payload/*.app/embedded.mobileprovision' | security cms -D | plutil -extract ProvisionedDevices json -o - - || true
ls -l ../ios/rcw-month-ios.ipa
echo "ok" > build/ipa.done
echo "✅ 完成：ios/rcw-month-ios.ipa（版本 $V）"

if [ "$1" = "--publish" ]; then
  cd ..
  git add ios/rcw-month-ios.ipa ios/manifest.plist
  git commit -m "iPhone／iPad App $V（Ad Hoc .ipa）" && git push && echo "✅ 已推上 GitHub，安裝頁約 1～5 分鐘後更新"
fi
