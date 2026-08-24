#!/bin/zsh
# rime-translate 一键安装（普通用户版）
# 无需源码和编译工具，从 GitHub Releases 下载预构建产物并完成安装。
#
#   curl -fL https://raw.githubusercontent.com/daocatt/rime-translate/main/scripts/install_remote.sh | zsh
#
# 或分步执行:
#   zsh install_remote.sh
set -euo pipefail

REPO="https://github.com/daocatt/rime-translate/releases/latest/download"
RIME_DIR="$HOME/Library/Rime"
APP_DIR="$HOME/Library/Application Support/rime-translate"
BIN_DST="/usr/local/bin/rime-translate-helper"
PLIST_DST="$HOME/Library/LaunchAgents/com.rimetranslate.helper.plist"
PORT=61899
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

[[ "$(uname)" == "Darwin" ]] || { echo "仅支持 macOS"; exit 1; }
[[ $(sw_vers -productVersion | cut -d. -f1) -ge 13 ]] || { echo "需要 macOS 13.0+"; exit 1; }
[[ -d "$RIME_DIR" ]] || { echo "错误: 未找到 $RIME_DIR —— 请先安装鼠鬚管(Squirrel) https://rime.im"; exit 1; }

echo "==> 下载安装文件..."
curl -fL --retry 3 --progress-bar -o "$TMP/helper"      "$REPO/rime-translate-helper"
curl -fL --retry 3 --progress-bar -o "$TMP/ecdict.db"   "$REPO/ecdict.db"
curl -fL --retry 3 --progress-bar -o "$TMP/rime_translate.lua" "$REPO/rime_translate.lua"

echo "==> 安装 helper 到 $BIN_DST（需要管理员权限）"
sudo install -m 755 "$TMP/helper" "$BIN_DST"

echo "==> 安装 lua filter 与离线词典"
mkdir -p "$RIME_DIR/lua" "$APP_DIR"
install -m 644 "$TMP/rime_translate.lua" "$RIME_DIR/lua/rime_translate.lua"
install -m 644 "$TMP/ecdict.db" "$APP_DIR/ecdict.db"

echo "==> 配置开机自启"
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST_DST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>com.rimetranslate.helper</string>
    <key>ProgramArguments</key>
    <array>
        <string>$BIN_DST</string>
        <string>--port</string>
        <string>$PORT</string>
    </array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>ProcessType</key><string>Background</string>
    <key>StandardOutPath</key><string>/tmp/rime-translate-helper.log</string>
    <key>StandardErrorPath</key><string>/tmp/rime-translate-helper.log</string>
</dict>
</plist>
EOF
launchctl bootout gui/"$(id -u)"/com.rimetranslate.helper 2>/dev/null || true
launchctl bootstrap gui/"$(id -u)" "$PLIST_DST"

sleep 1
if curl -fsS --max-time 2 "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; then
    echo "==> helper 运行正常: $(curl -s http://127.0.0.1:$PORT/health)"
else
    echo "警告: helper 未响应，查看 /tmp/rime-translate-helper.log"
fi

SCHEMA_HINT="$RIME_DIR/luna_pinyin.custom.yaml"
cat <<EOF

==================================================================
安装完成！还差最后一步 —— 把 filter 挂到你的输入方案里：

方法 A（命令行，以朙月拼音为例）：
  cat > "$SCHEMA_HINT" <<'PATCH'
patch:
  engine/filters/+:
    - lua_filter@*rime_translate
PATCH

方法 B：手动编辑你所用方案的 *.custom.yaml，加入上面 patch 内容。

然后在菜单栏【ㄓ】图标选择「重新部署」。

可选开启 AI 兜底（离线词典未命中的词走 Cloudflare 翻译）：
  创建 "$APP_DIR/config.json":
    {"account_id":"<CF账号ID>","api_token":"<API Token>","model":"@cf/meta/m2m100-1.2B"}
  然后执行: launchctl kickstart -k gui/\$(id -u)/com.rimetranslate.helper
==================================================================
EOF
