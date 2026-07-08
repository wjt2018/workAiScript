# 工作日报 / 周报 / 月报自动生成

一套跑在 Windows 上的自动化脚本:每个**中国工作日**傍晚自动汇总你当天的工作,用
本地的 `claude` CLI 整理成一份**英文、按项目分组**的日报,存档到本地并**通过 Slack 私信发给你**。
到了周五自动把本周日报合并成周报,到了月底再把本月周报合并成月报——你几乎不用管。

---

## 一、这个工具能做什么

**自动收集三个来源的当日工作:**

- **本地 git 提交** —— 扫描你配置的所有本地仓库,按你的邮箱 / 名字过滤出你自己的提交
- **GitHub 已推送提交** —— 通过 `gh search commits --author @me` 补全那些没在本地仓库列表里、但已推到 GitHub 的提交
- **Google 日历** —— 读取当天日程(会议、评审等),REST 直连,无头运行
- **Slack 发言** —— 读取你当天在频道 / 群聊里发的消息(排除一对一私信)

**自动生成并投递:**

- 用本地 `claude -p`(无头模式)把原始数据整理成**英文、按项目分组**的报告
- 报告存到 `reports/YYYY-MM-DD.md`,同时**通过 Slack bot 私信发给你**,渲染成原生的多级项目符号列表

**三级汇总,层层归并:**

| 周期 | 触发时间 | 做什么 |
|------|----------|--------|
| **日报** | 每个工作日 17:50 | 汇总当天三源数据 → 生成日报 |
| **周报** | 每周五 18:00 | 合并本周日报,同项目多天的工作**归并成一条** → 删除已合并的日报 |
| **月报** | 每月最后一天 18:10 | 合并当月周报(+残留日报),同项目跨周工作**归并成一条** → 删除已合并的源文件 |

**贴合中国工作日历:**

- 自动跳过法定节假日,并在**调休上班**的周六 / 周日照常运行(数据来自官方节假日表,本地缓存)
- 任务每天触发,是否真正运行由脚本内部的工作日判断决定

**容错设计:**

- 日历 / Slack / 发送任一项未配置时**自动跳过**,不影响其它部分照常出报告
- `claude` 调用失败时保存原始拼接版,并**不删除**源文件,方便之后手动重跑

**输出格式示例**(英文,按项目分组,两级缩进;规则写在 `prompt-template.txt` 里,随时可改):

```
Today:
- Website:
  - Build PDP A/B test sections
  - Fix blog-management ldjson issue
- Admin:
  - Review order status search, flag missing card brand values
```

---

## 二、如何使用

### 前提条件

| 依赖 | 是否必需 | 说明 |
|------|----------|------|
| **Windows + PowerShell 5.1** | 必需 | 系统自带,无需额外安装。脚本靠计划任务(Task Scheduler)运行 |
| **Claude Code(`claude` CLI)** | 必需 | 报告由本地 `claude -p` 无头生成,是整套工具的核心 |
| **`git`** | 必需 | 用来扫描本地仓库的提交 |
| **`gh`(GitHub CLI)** | 可选 | 开了 `useGhSearch` 时用它补全已推送到 GitHub 的提交,需先 `gh auth login` |
| **Slack workspace** | 可选 | 不配就跳过 Slack 收集 / 发送 |
| **Google 账号** | 可选 | 不配就跳过日历收集 |

**安装并登录 Claude Code:**

```powershell
# 安装(需要 Node.js 18+)
npm install -g @anthropic-ai/claude-code

# 登录(按提示在浏览器完成授权)
claude
```

装好后在任意目录运行一下 `claude -p "say hi"`,能正常返回说明就绪。脚本正是靠这条无头调用来生成报告的。

> 各依赖是否就位,可以逐条验证:`claude --version`、`git --version`、`gh --version`。

### 第 1 步:配置要扫描的仓库

复制 `config.example.json` 为 `config.json`,填上你自己的信息:

```powershell
Copy-Item config.example.json config.json
```

然后编辑 `config.json`:

- `authorEmails` / `authorNames`:你的Git提交邮箱和名字(任一命中即算你的提交)
- `repos`:要扫描的本地仓库绝对路径列表
- `useGhSearch`:是否用 `gh` 补全已推送到 GitHub 的其它仓库提交

> `config.json` 含你的个人信息,不要提交到公开仓库(已在 `.gitignore` 里排除)。

### 第 2 步:一次性授权(都是可选的,不配就跳过)

所有令牌都存在本地的 `secrets.json`,**绝不要提交 git**。

#### Slack —— 读取你的发言

1. 打开 <https://api.slack.com/apps> → **Create New App** → **From scratch**(名字随意,选你的 workspace)
2. 左侧 **OAuth & Permissions** → 找到 **User Token Scopes**(注意不是 Bot!)→ 添加 `search:read`
3. 页面顶部 **Install to Workspace** → **Allow**
4. 复制 **User OAuth Token**(`xoxp-` 开头)
5. 运行并粘贴:
   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File .\setup-slack.ps1
   ```

> 组织类 workspace 安装 / 重装带新权限的应用通常需要**管理员审批**;加了 scope 后记得重装才会生成 `xoxp` token。

#### Slack —— 把日报私信发给你

1. 同一个 app → **OAuth & Permissions** → 复制 **Bot User OAuth Token**(`xoxb-` 开头)
2. bot 需要 `chat:write`(发消息)和 `im:write`(开私信)两个 **Bot Token Scopes**
3. 运行并粘贴:
   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File .\setup-slack-send.ps1
   ```

#### Google 日历 —— 读取当天日程

1. <https://console.cloud.google.com/> 新建 / 选择一个项目
2. **APIs & Services → Library** → 启用 **Google Calendar API**
3. **APIs & Services → OAuth consent screen**:User Type 选 **External**,填应用名和邮箱;
   在 **Test users** 里加上你自己的 Google 账号
4. **APIs & Services → Credentials → Create Credentials → OAuth client ID**
   → Application type 选 **Desktop app** → 创建 → 复制 **Client ID** 和 **Client Secret**
5. 运行(会弹浏览器让你授权,只读日历):
   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File .\setup-google.ps1
   ```

> 想用非主日历?在 `secrets.json` 里加 `"calendar": { "calendarId": "xxx@group.calendar.google.com" }`。

### 第 3 步:注册计划任务

```powershell
# 日报:每天 17:50(脚本内部判断是否工作日)
powershell -NoProfile -ExecutionPolicy Bypass -File .\register-task.ps1

# 周报:每周五 18:00
powershell -NoProfile -ExecutionPolicy Bypass -File .\register-weekly-task.ps1

# 月报:每月最后一天 18:10
powershell -NoProfile -ExecutionPolicy Bypass -File .\register-monthly-task.ps1
```

> 计划任务以当前用户身份运行,**仅在你登录 Windows 时触发**;
> 若到点电脑没开,会在下次开机后补跑(StartWhenAvailable)。

### 手动运行 / 测试

```powershell
# 立即跑一次日报(-Force 跳过工作日检查,方便测试)
powershell -NoProfile -ExecutionPolicy Bypass -File .\daily-report.ps1 -Force

# 补跑某一天
powershell ... -File .\daily-report.ps1 -Date 2026-07-01 -Force

# 周报:-KeepDaily 不删日报;-Date 指定"周五"补跑某周
powershell ... -File .\weekly-report.ps1 -KeepDaily
powershell ... -File .\weekly-report.ps1 -Date 2026-07-10

# 月报:-KeepSource 不删源文件;-Month 补跑某月
powershell ... -File .\monthly-report.ps1 -KeepSource
powershell ... -File .\monthly-report.ps1 -Month 2026-06

# 单独测试某个数据源
. .\collect-slack.ps1;    Get-SlackDigest    -DateStr (Get-Date -Format yyyy-MM-dd) -Root $PWD
. .\collect-calendar.ps1; Get-CalendarDigest -DateStr (Get-Date -Format yyyy-MM-dd) -Root $PWD
```

### 管理计划任务

```powershell
# 立即触发 / 看下次运行时间
Start-ScheduledTask -TaskName WorkAiDailyReport
(Get-ScheduledTask -TaskName WorkAiDailyReport | Get-ScheduledTaskInfo).NextRunTime

# 暂停 / 恢复 / 删除
Disable-ScheduledTask    -TaskName WorkAiDailyReport
Enable-ScheduledTask     -TaskName WorkAiDailyReport
Unregister-ScheduledTask -TaskName WorkAiDailyReport -Confirm:$false
```

> 三个任务名分别是 `WorkAiDailyReport` / `WorkAiWeeklyReport` / `WorkAiMonthlyReport`。

---

## 三、其他信息

### 文件说明

| 文件 | 作用 |
|------|------|
| `daily-report.ps1` | 主脚本:判断工作日 → 收集三源数据 → 调 claude → 写日报 → Slack 私信 |
| `weekly-report.ps1` | 周报:合并本周日报 → 调 claude 归并同类任务 → Slack 私信 → 删除已合并日报 |
| `monthly-report.ps1` | 月报:合并当月周报(+残留日报)→ 调 claude 归并 → Slack 私信 → 删除已合并源文件 |
| `collect-calendar.ps1` | 读取当天 Google 日历日程(用存好的 refresh token) |
| `collect-slack.ps1` | 读取当天你在 Slack 频道 / 群聊的发言(排除一对一私信) |
| `send-slack.ps1` | 把生成好的报告通过 bot 私信发给你(渲染成原生列表) |
| `lib-workday.ps1` | 中国工作日判断(节假日 + 调休),数据缓存在 `cache/` |
| `lib-secrets.ps1` | 读写 `secrets.json` 的小工具 |
| `setup-google.ps1` | **一次性**:Google 授权,拿到并保存 refresh token |
| `setup-slack.ps1` | **一次性**:保存并校验 Slack User Token(`xoxp`,用于读取发言) |
| `setup-slack-send.ps1` | **一次性**:保存 Slack Bot Token(`xoxb`,用于发送报告) |
| `register-task.ps1` | 注册 / 刷新日报计划任务(每天 17:50) |
| `register-weekly-task.ps1` | 注册 / 刷新周报计划任务(每周五 18:00) |
| `register-monthly-task.ps1` | 注册 / 刷新月报计划任务(每月最后一天 18:10) |
| `prompt-template.txt` | 日报提示词模板(UTF-8,可改格式 / 语气) |
| `prompt-template-week.txt` | 周报提示词模板(UTF-8,可改归并规则) |
| `prompt-template-month.txt` | 月报提示词模板(UTF-8,可改归并规则) |
| `config.example.json` | 配置模板,复制成 `config.json` 后填自己的信息 |
| `config.json` | 你的仓库列表 / 邮箱 / 名字(**含个人信息,勿提交公开仓库**) |
| `secrets.json` | **令牌存放处(绝不提交 git)**,由三个 setup 脚本生成 |
| `reports/` `logs/` `cache/` | 报告存档 / 运行日志 / 节假日缓存 |

### 为什么用本地令牌 + REST,而不用 claude 的 MCP 连接器?

计划任务是**无头运行**——到点自动触发时,你可能在开会、锁屏,没人能点授权弹窗。
claude.ai 的 MCP 连接器授权是为**交互式会话**设计的,token 失效时需要人重新授权,
在无头环境下不可靠,一旦失效报告会静默缺数据。

所以日历 / Slack 都用**本地存的长期令牌 + REST 直连**:Google 的 refresh token 长期有效,
脚本每次运行自己换取 access token;Slack 的 `xoxp` / `xoxb` 也长期有效,全程无需人工介入。

此外,数据收集交给确定性的脚本、claude 只负责最后一步"整理归纳",分工更稳,也更省 token。

### 关于编码

> ⚠️ 所有 `.ps1` 脚本**故意只用 ASCII**,中文放在 `prompt-template*.txt`(按 UTF-8 读取)。
> 这样 zh-CN 的 PowerShell 5.1 不会把中文源码读成乱码。改脚本时请勿在 `.ps1` 里写中文。

### 节假日数据来源

工作日判断用的是社区维护的官方节假日表
([holiday-cn](https://github.com/NateScarlet/holiday-cn)),按年缓存在 `cache/holiday-<year>.json`。
拿不到数据时回退到"周一至周五上班"的默认规则。

### 定制报告格式

三份 `prompt-template*.txt` 就是给 claude 的提示词,决定报告的语言、分组方式、归并粒度。
想改成中文、想换项目分组规则、想让月报更简略——直接改模板即可,无需动脚本(记得保持 UTF-8 编码)。
