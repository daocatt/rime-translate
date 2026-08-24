# rime-translate

为 [鼠鬚管 Squirrel](https://github.com/rime/squirrel)（macOS）提供中→英翻译注释：
输入拼音时，中文候选词旁直接显示英文释义。离线词典基于 [ECDICT](https://github.com/skywind3000/ECDICT)，
可选 Cloudflare Workers AI 兜底翻译词典未收录的词。

```
横向候选:  1. 苹果  apple
竖向候选:  1. 苹果  apple / fruit / malus / pome
```

## 安装

**要求**：macOS 13.0+，已安装并使用 [鼠鬚管 Squirrel](https://rime.im)。

### 第 1 步：一键安装

```bash
curl -fL https://raw.githubusercontent.com/daocatt/rime-translate/main/scripts/install_remote.sh | zsh
```

脚本会自动下载并安装三样东西：

| 内容 | 位置 |
|---|---|
| helper 常驻进程（词典查询 + AI 兜底） | `/usr/local/bin/rime-translate-helper` |
| Lua 翻译插件 | `~/Library/Rime/lua/rime_translate.lua` |
| 全量离线词典（ECDICT 反向索引） | `~/Library/Application Support/rime-translate/ecdict.db` |

并注册开机自启（LaunchAgent），安装过程需要输入一次管理员密码。

### 第 2 步：挂载到你的输入方案

以朙月拼音为例（其他方案把文件名换成对应的 `*.custom.yaml`）：

```bash
cat > ~/Library/Rime/luna_pinyin.custom.yaml <<'EOF'
patch:
  engine/filters/+:
    - lua_filter@*rime_translate
EOF
```

### 第 3 步：重新部署

菜单栏【ㄓ】图标 → **重新部署**（或终端执行）：

```bash
"/Library/Input Methods/Squirrel.app/Contents/MacOS/Squirrel" --reload
```

### 第 4 步：验证

打开任意文本编辑器，输入 `pingguo`：
- 候选「苹果」旁出现 `apple` → 安装成功
- 横排最多显示 2 个英文词，竖排最多 5 个（可配置）

### 可选：开启 AI 兜底

离线词典未收录的词自动走 Cloudflare Workers AI 翻译并缓存到本地：

```bash
mkdir -p ~/Library/Application\ Support/rime-translate
cat > ~/Library/Application\ Support/rime-translate/config.json <<'EOF'
{"account_id":"<Cloudflare账号ID>","api_token":"<Workers AI权限的Token>","model":"@cf/meta/m2m100-1.2B"}
EOF
launchctl kickstart -k gui/$(id -u)/com.rimetranslate.helper
```

Token 需在 Cloudflare 控制台创建，权限勾选 **Workers AI**。

### 常用配置与排障

自定义显示数量等（改完需重新部署）——`~/Library/Rime/rime_translate.custom.yaml`：

```yaml
patch:
  translate/max_entries_horizontal: 2   # 横向最多几个英文词
  translate/max_entries_vertical: 5     # 纵向最多几个
  translate/enabled: true               # 总开关
```

| 问题 | 排查 |
|---|---|
| 候选没有英文注释 | `curl http://127.0.0.1:61899/health` 应返回 `{"status":"ok",...}`；查看 `/tmp/rime-translate-helper.log`；确认已重新部署 |
| helper 未运行 | `launchctl kickstart -k gui/$(id -u)/com.rimetranslate.helper` |
| 卸载 | `sudo rm /usr/local/bin/rime-translate-helper ~/Library/LaunchAgents/com.rimetranslate.helper.plist && rm -rf ~/Library/Application\ Support/rime-translate ~/Library/Rime/lua/rime_translate.lua` 并从方案 patch 中移除该 filter |

## 许可协议

- 本项目代码：**MIT**（见 [LICENSE](LICENSE)）
- 词典数据来自 [ECDICT](https://github.com/skywind3000/ECDICT)（MIT，见 [`LICENSES/ECDICT-LICENSE.txt`](LICENSES/ECDICT-LICENSE.txt)）
- 本项目是运行时插件，不包含、不修改、不分发 Squirrel/librime 源码或二进制
