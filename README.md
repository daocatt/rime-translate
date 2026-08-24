# rime-translate

为 [鼠鬚管 Squirrel](https://github.com/rime/squirrel)（macOS）提供**中→英翻译注释**：
输入拼音时，中文候选词旁直接显示英文释义，适合中文输入的同时顺带学英文。

```
横向候选:  1. 苹果  apple
竖向候选:  1. 苹果  apple / fruit / malus / pome
```

**特性**

- 离线词典 273 万词条：ECDICT（反排清洗）+ CC-CEDICT（原生中英）双源合并
- **打字零阻塞**：常用词微秒级命中；生僻词异步回填，永不卡输入
- **AI 兜底 + 自我进化**：词典没有的词自动调 Cloudflare Workers AI 翻译，
  结果沉淀到本地库，越用越准
- 不修改 Squirrel 源码，纯官方插件机制接入

---

## 安装

**要求**：macOS 13.0+，已安装并使用[鼠鬚管 Squirrel](https://rime.im)。

```bash
curl -fL https://raw.githubusercontent.com/daocatt/rime-translate/main/scripts/install_remote.sh | zsh
```

脚本自动安装三样东西：

| 内容 | 位置 |
|---|---|
| helper 常驻进程（查询 + AI 兜底） | `/usr/local/bin/rime-translate-helper` |
| Lua 翻译插件 | `~/Library/Rime/lua/rime_translate.lua` |
| 全量离线词典 | `~/Library/Application Support/rime-translate/ecdict.db` |

并注册开机自启（需要输入一次管理员密码）。

### 挂载到输入方案

以朙月拼音为例（其他方案改对应文件名）：

```bash
cat > ~/Library/Rime/luna_pinyin.custom.yaml <<'EOF'
patch:
  engine/filters/+:
    - lua_filter@*rime_translate
EOF
```

### 重新部署

菜单栏【ㄓ】→ **重新部署**，或：

```bash
"/Library/Input Methods/Squirrel.app/Contents/MacOS/Squirrel" --reload
```

### 验证

打开文本编辑器，切换到鼠鬚管，输入：

```
pingguo   → 苹果 apple
diannao   → 电脑 computer
xuesheng  → 学生 student
```

横排最多显示 2 个英文词，竖排最多 5 个。

---

## 开启 AI 兜底（可选但强烈推荐）

离线词典没有的词（网络新词、人名、专业术语），helper 会自动请求
Cloudflare Workers AI 翻译并**永久缓存到本地**——同一个词只翻译一次，
之后完全离线可用。

### 第 1 步：创建 API Token

1. 登录 [Cloudflare Dashboard](https://dash.cloudflare.com/profile/api-tokens)
2. 创建 Token → 权限选择 **Account → Workers AI → Edit**
3. 记下 Token 和账户 ID（账户概览页右侧可见）

> ⚠️ Token 等同密码，不要提交到任何代码仓库或聊天窗口。
> 怀疑泄露时在 Dashboard 里 Roll（轮换）即可作废旧 Token。

### 第 2 步：写入配置

```bash
mkdir -p ~/Library/Application\ Support/rime-translate
cat > ~/Library/Application\ Support/rime-translate/config.json <<'EOF'
{
  "account_id": "你的Cloudflare账户ID",
  "api_token": "你的Workers_AI_Token",
  "model": "@cf/meta/llama-3.3-70b-instruct-fp8-fast",
  "timeout_seconds": 20
}
EOF
chmod 600 ~/Library/Application\ Support/rime-translate/config.json
launchctl kickstart -k gui/$(id -u)/com.rimetranslate.helper
```

该文件在用户目录下，**永远不会被 git 收录**。

### 推荐模型

| 模型 | 质量 | 免费额度消耗 | 建议 |
|---|---|---|---|
| `@cf/meta/llama-3.3-70b-instruct-fp8-fast` | ★★★★★ | 较高 | **默认推荐**，单词翻译质量最好 |
| `@cf/meta/m2m100-1.2b` | ★★☆ | ~0.3 neurons/次，极低 | 大批量跑时省钱用；单词质量一般 |

修改 `config.json` 的 `model` 字段后执行
`launchctl kickstart -k gui/$(id -u)/com.rimetranslate.helper` 即可生效，
无需重装。两种模型的返回格式 helper 会自动识别。

### 效果示例

```
内卷     → involution
尊嘟假嘟 → by Fake Dude          （词典查不到 → AI 兜底）
```

### API 调用示例（供调试）

```bash
curl https://api.cloudflare.com/client/v4/accounts/$CLOUDFLARE_ACCOUNT_ID/ai/run/@cf/meta/m2m100-1.2b \
    -X POST \
    -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
    -H "Content-Type: application/json" \
    -d '{ "text": "人工智能", "source_lang": "chinese", "target_lang": "english" }'

curl https://api.cloudflare.com/client/v4/accounts/$CLOUDFLARE_ACCOUNT_ID/ai/run/@cf/meta/llama-3.3-70b-instruct-fp8-fast \
    -X POST \
    -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
    -H "Content-Type: application/json" \
    -d '{"messages":[{"role":"system","content":"Translate the Chinese word or phrase to English. Reply with up to 3 English translations separated by | , nothing else."},{"role":"user","content":"测试"}],"max_tokens":40}'
```

注意模型 ID 区分大小写（是 `m2m100-1.2b` 不是 `1.2B`）。
`@cf/ai4bharat/indictrans2-*` 系列**不支持中文**，勿用。

### 批量增强词典

用免费额度把高频词批量翻译沉淀进本地库（断点续跑）：

```bash
python3 scripts/enrich_ai.py --db ~/Library/Application\ Support/rime-translate/ecdict.db \
    --account <CF账号ID> --token <API Token> --limit 200 \
    --model "@cf/meta/llama-3.3-70b-instruct-fp8-fast"
```

结果写入 db 的 `ai_cache` 表并自动进入热缓存，**优先于原始词典显示**。

---

## 常用配置

`~/Library/Rime/rime_translate.custom.yaml`（改完需重新部署）：

```yaml
patch:
  translate/max_entries_horizontal: 2   # 横排最多几个英文词
  translate/max_entries_vertical: 5     # 竖排最多几个
  translate/separator: " / "
  translate/orientation_override: auto  # auto | horizontal | vertical
  translate/helper_port: 61899
  translate/max_candidate_len: 12       # 超长候选不翻译
  translate/enabled: true               # 总开关
```

横竖排会自动跟随主题的 `candidate_list_layout`（linear=横 / stacked=竖）设置。

## 工作原理

```
┌─ Squirrel ─────────────────────────────────┐
│ lua filter: 内存缓存 → 热缓存(3万高频词)    │  ← 打字路径, 微秒级
│             未命中词追加一行到请求文件       │  ← 文件写入, 无阻塞
└─────────────────────────────────────────────┘
        │ 版本号变化时重载热缓存(读一行)
┌─ rime-translate-helper (常驻) ─────────────┐
│  每秒消化请求文件:                          │
│   SQLite 离线库 → Cloudflare Workers AI    │  ← 异步, 永不阻塞打字
│  结果写入 ai_cache → 刷新热缓存(#rev+1)    │
└─────────────────────────────────────────────┘
```

## 排障

| 问题 | 处理 |
|---|---|
| 候选没注释 | `curl http://127.0.0.1:61899/health` 应返回 ok；确认已重新部署 |
| helper 未运行 | `launchctl kickstart -k gui/$(id -u)/com.rimetranslate.helper` |
| 冷门词第一次没翻译 | 正常——停 1~2 秒再打就有了（异步回填） |
| 想看 filter 内部行为 | `tail -f /tmp/rime_translate_debug.log`（自动限 512KB） |
| AI 报错 | 检查 `/tmp/rime-translate-helper.log`；确认 Token 有 Workers AI 权限 |

## 卸载

```bash
sudo rm /usr/local/bin/rime-translate-helper
rm ~/Library/LaunchAgents/com.rimetranslate.helper.plist
rm -rf ~/Library/Application\ Support/rime-translate
rm ~/Library/Rime/lua/rime_translate.lua
# 并从方案的 *.custom.yaml 中删除 engine/filters/+ 那两行，重新部署
launchctl bootout gui/$(id -u)/com.rimetranslate.helper 2>/dev/null
```

## 开发者指南

```bash
# 构建 ECDICT sqlite 可从 https://github.com/skywind3000/ECDICT/releases 下载
# CC-CEDICT 从 https://www.mdbg.net/chinese/dictionary?page=cedict 下载
python3 scripts/build_dict.py stardict.db --cedict cedict.txt \
    --zh-freq jieba_freq.txt -o dist/ecdict.db

# 编译通用二进制 (arm64 + x86_64)
swiftc -O -o /tmp/h1 helper/main.swift -lsqlite3 -target arm64-apple-macosx13.0
swiftc -O -o /tmp/h2 helper/main.swift -lsqlite3
lipo -create /tmp/h1 /tmp/h2 -output dist/rime-translate-helper

# 本机安装（开发者版）
zsh scripts/install.sh

# 单元测试
HOME=$PWD/tests/fixtures/home lua tests/test_filter.lua
HOME=$PWD/tests/fixtures/home2 EXPECT_LAYOUT=horizontal lua tests/test_filter.lua

# 发布 Release（gh cli 已登录）
zsh scripts/release.sh
```

已知取舍：候选注释通过 librime-lua 的 comment 机制渲染，位置跟随主题；
若要"横排放下方第二行"的定制布局需 fork Squirrel 改 UI（其源码为 GPL-3.0）。

## 许可协议

- 本项目代码：**MIT**（见 [LICENSE](LICENSE)）
- 词典数据：[ECDICT](https://github.com/skywind3000/ECDICT)（MIT）+ [CC-CEDICT](https://www.mdbg.net/chinese/dictionary?page=cedict)（CC-BY-SA 4.0）
  —— 合并后的数据包 `ecdict.db` 按 **CC-BY-SA 4.0** 分发，详见 [`LICENSES/`](LICENSES/)
- 构建期使用了 [jieba](https://github.com/fxsjy/jieba) 词频表（Apache-2.0，仅用于排序）
- 本项目是运行时插件，不包含、不修改、不分发 Squirrel/librime 源码或二进制
