#!/bin/zsh
# 构建发布产物并上传到 GitHub Releases。
#
# 用法:
#   zsh scripts/release.sh            # 使用已有 dist/ecdict.db
#   zsh scripts/release.sh ecdict.csv # 先从 csv 构建
#
# 前置条件:
#   - gh CLI 已登录: gh auth login
#   - 已创建远端仓库 daocatt/rime-translate
set -euo pipefail

cd "$(dirname "$0")/.."
VERSION="${1:-}"
ASSETS_DIR=dist

if [[ -n "$VERSION" && -f "$VERSION" ]]; then
    echo "==> 从 $VERSION 构建全量词典..."
    python3 scripts/build_dict.py "$VERSION" -o "$ASSETS_DIR/ecdict.db"
fi
[[ -f "$ASSETS_DIR/ecdict.db" ]] || { echo "缺少 dist/ecdict.db"; exit 1; }
[[ -f "$ASSETS_DIR/rime-translate-helper" ]] || { echo "缺少 helper，先编译:"; \
    echo "  swiftc -O -o /tmp/h1 helper/main.swift -lsqlite3 -target arm64-apple-macosx13.0"; \
    echo "  swiftc -O -o /tmp/h2 helper/main.swift -lsqlite3"; \
    echo "  lipo -create /tmp/h1 /tmp/h2 -output dist/rime-translate-helper"; exit 1; }

echo "==> 准备发布资产"
cp rime/rime_translate.lua "$ASSETS_DIR/rime_translate.lua"
du -h "$ASSETS_DIR"/ecdict.db "$ASSETS_DIR"/rime-translate-helper "$ASSETS_DIR"/rime_translate.lua

TAG="v$(date +%Y.%m.%d)"
echo "==> 创建 release $TAG 并上传"
gh release create "$TAG" \
    --repo daocatt/rime-translate \
    --title "rime-translate $TAG" \
    --notes "离线中英词典 (基于 ECDICT, MIT) + helper 通用二进制 (macOS 13+, arm64/x86_64)" \
    "$ASSETS_DIR/ecdict.db" \
    "$ASSETS_DIR/rime-translate-helper" \
    "$ASSETS_DIR/rime_translate.lua"

echo "==> 完成。用户安装命令:"
echo "   curl -fL https://raw.githubusercontent.com/daocatt/rime-translate/main/scripts/install_remote.sh | zsh"
