#!/bin/zsh
# rime-translate installer (macOS)
# Installs: helper binary, lua filter, offline dictionary, LaunchAgent.
set -euo pipefail

RIME_DIR="$HOME/Library/Rime"
APP_DIR="$HOME/Library/Application Support/rime-translate"
BIN_DST="/usr/local/bin/rime-translate-helper"
PLIST_DST="$HOME/Library/LaunchAgents/com.rimetranslate.helper.plist"
DB_URL="${RIME_TRANSLATE_DB_URL:-https://github.com/daocatt/rime-translate/releases/latest/download/ecdict.db}"

[[ -d "$RIME_DIR" ]] || { echo "error: $RIME_DIR not found (is Rime installed?)"; exit 1; }

echo "==> installing helper binary to $BIN_DST"
sudo install -m 755 dist/rime-translate-helper "$BIN_DST"

echo "==> installing lua filter"
mkdir -p "$RIME_DIR/lua"
install -m 644 rime/rime_translate.lua "$RIME_DIR/lua/rime_translate.lua"

echo "==> installing offline dictionary"
mkdir -p "$APP_DIR"
if [[ -f dist/ecdict.db ]]; then
    install -m 644 dist/ecdict.db "$APP_DIR/ecdict.db"
else
    echo "    downloading ecdict.db from $DB_URL"
    curl -fL --retry 3 -o "$APP_DIR/ecdict.db" "$DB_URL"
fi

echo "==> installing LaunchAgent"
mkdir -p "$HOME/Library/LaunchAgents"
install -m 644 launchd/com.rimetranslate.helper.plist "$PLIST_DST"
launchctl bootout gui/"$(id -u)"/com.rimetranslate.helper 2>/dev/null || true
launchctl bootstrap gui/"$(id -u)" "$PLIST_DST"

sleep 1
if curl -fsS --max-time 2 http://127.0.0.1:61899/health >/dev/null; then
    echo "==> helper is running: $(curl -s http://127.0.0.1:61899/health)"
else
    echo "warning: helper did not answer on port 61899, see /tmp/rime-translate-helper.log"
fi

cat <<'EOF'

==> done. Final steps (manual):
    1. add to your schema *.custom.yaml:
         patch:
           engine/filters/+:
             - lua_filter@*rime_translate
    2. optional config: ~/Library/Rime/rime_translate.custom.yaml
       (see rime/rime_translate.custom.yaml.example)
    3. optional AI fallback: create
       "~/Library/Application Support/rime-translate/config.json":
         {"account_id":"<CF_ACCOUNT_ID>","api_token":"<CF_API_TOKEN>",
          "model":"@cf/meta/m2m100-1.2b"}
    4. redeploy Squirrel
EOF
