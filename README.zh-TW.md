# opencode Orchestration Skill

[English](README.md) | 繁體中文

這是把工作分派給多個 opencode 工作代理的技能，協調者保留規劃、監督、審查與部署。它與 [codex-orchestration](https://github.com/Zakk-LLM/codex-orchestration) 是同一套設計的姊妹版：相同的執行目錄、難度分級、審查閘門與原子整合，底層引擎不同。

分工固定：工作代理只產出程式碼與草稿；協調者讀真實 diff、執行測試、寫審查結論；commit、merge、發佈由協調者執行。

## 要求

- opencode 1.18 或更新版本，且已設定可用的供應商
- Python 3.11 或更新版本
- Bash

## 安裝

```bash
git clone <repository-url> opencode-orchestration
cd opencode-orchestration
./install.sh
```

| 代理 | 安裝位置 |
|---|---|
| Claude | `~/.claude/skills/opencode` |
| Codex | `${CODEX_HOME:-~/.codex}/skills/opencode` |
| OpenCode | `~/.config/opencode/skills/opencode` |

## 這個引擎的差異

**禁令由引擎執行，不只是要求**。`--permission workspace-write` 在工具層直接拒絕 `git commit`、`push`、`rebase`、`checkout`、`reset`、`merge` 與破壞性 shell 命令。codex 版只能把這些規則寫進任務規格。

**具名代理預設**。`--agent <name>` 直接沿用 opencode 設定檔中定義的代理。

**工作階段分叉**。`--fork` 從既有理解分出另一條路線，原本的討論串保持不變。

**每次執行的花費**。`meta.json` 除 token 外另記錄金額，資料取自引擎自身的事件。

**沒有沙箱**。codex 以作業系統層級限制工作代理，opencode 只有權限規則，因此權限設定就是全部的邊界。不要用它執行不受信任的工作。

**沒有結構化輸出強制**。opencode 沒有 `--output-schema`。包裝腳本把 schema 附加到提示詞，執行後驗證最終訊息，不符合時離開碼 65 並記錄 `schema_error`。模型是被要求，不是被強制。

## 使用

```bash
RUN=$(scripts/oc_new_run.sh add-auth-cache)
scripts/oc_capacity.sh medium
scripts/oc_agents.sh --list

scripts/oc_agent.sh --run-dir "$RUN" --label cache \
  --cwd /path/to/repo --worktree --permission workspace-write \
  --tier deep --timeout 1800 --stall 300 \
  --prompt-file "$RUN/agents/cache/prompt.md" --schema "$RUN/schema/impl.json"

scripts/oc_dispatch.sh --run-dir "$RUN" --jobs "$RUN/jobs.jsonl" --weight medium
scripts/oc_watch.sh "$RUN" --timeout 120 --peek
scripts/oc_verify.sh "$RUN" cache --check "pytest -q"
scripts/oc_merge.sh --run-dir "$RUN" --repo /path/to/repo --into main --check "pytest -q"
```

各腳本的 `--help` 列出全部選項。

## 權限設定檔

| 設定檔 | 授予 | 用於 |
|---|---|---|
| `read-only` | 讀取類工具，加上一組檢視命令的允許清單 | 研究、稽核、審查 |
| `workspace-write` | 可編輯，bash 扣除破壞性命令與改寫歷史的 git | 實作 |
| `full` | 除改寫歷史的 git 之外全部允許 | 未取得明確同意即不使用 |
| `bypass` | 全部允許，含 git，並加上 `--auto` | 只用於你願意直接給出 shell 的工作區 |

`bypass` 會印出警告，永遠不是預設值。具名預設則承載完整角色：`--agent <name>` 使用 `~/.config/opencode/agent/<name>.md` 定義的代理，把模型、溫度、可用工具與權限固定在同一處。

`--network` 開放 webfetch，預設關閉；`--allow-git` 解除 git 禁令。設定檔中絕不可出現 `ask`，因為非互動執行沒有人能回答，會一直等到時限結束。權限透過 `OPENCODE_CONFIG_CONTENT` 合併進使用者設定，因此供應商、模型與 MCP 伺服器維持不變，只有這次執行的邊界改變。

## 其餘部分

難度分級、依賴排序、worktree 隔離、有時限的等待、逾時預警、回歸範圍工具、審查閘門與原子整合，行為與姊妹技能完全相同。流程見 [SKILL.md](SKILL.md)，細節見 `references/`：

- [references/prompt-template.md](references/prompt-template.md)
- [references/schemas.md](references/schemas.md)
- [references/worktrees.md](references/worktrees.md)
- [references/review-gate.md](references/review-gate.md)
- [references/troubleshooting.md](references/troubleshooting.md)

## 已知限制

- `opencode run` 會在繼承而來的 stdin 上無限等待，包裝腳本因此把 stdin 導向 `/dev/null`。
- 沒有內建時間上限，全部呼叫以 `timeout` 包裝並先送 SIGINT。
- 設定檔中列出的模型不代表帳號後端提供，404 會在付費派工數秒後才出現，所以 `opencode models` 屬於前置檢查。
- 兩個代理寫入同一個工作區會互相覆蓋，以 worktree 與 `PLAN.md` 的檔案歸屬預防。

## 授權

MIT
