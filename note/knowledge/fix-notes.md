# Resonance.nvim 架构梳理与评析

> 评审对象：`resonance.nvim`（约 2250 行 Lua，`lua/resonance/` 下 11 个模块）
> 评审日期：2026-10-17
> 评审环境：Neovim **0.12.6**（LuaJIT 2.1），仓库根目录直接入 `rtp` 做 headless 实测
> 说明：本文是架构快照，结论基于当时的 `HEAD`（`c673fbb`）。带「实测」标记的结论均已在本机复现。
>
> **2026-11-17 复核：** 本文的问题清单已对照当前源码（`38375de`）逐条核验。
> 已过时的行已划掉并注明原因，新发现的问题已补入。
> **当前唯一权威的待办清单是仓库根目录的 `plan.md`** —— 本文保留架构分析价值，
> 但不再作为执行依据。

---

## 1. 定位与分层

一句话：**`vim.pack`（Neovim 原生包管理）之上的一层"懒加载 + 构建钩子 + 管理面板"薄壳**，自己不做下载、不做锁文件、不做版本解析，全部委托给 `vim.pack.add/get/update/del`。

代码分五层：

```text
             ┌──────────────────────────────┐
             │  resonance/init.lua (门面)    │ setup / load / stats / open_ui / verylazy
             └──────────────┬───────────────┘
                            │
        ┌───────────────────┼─────────────────────┐
        ▼                   ▼                     ▼
 ┌─────────────┐    ┌──────────────┐      ┌──────────────┐
 │ loader/*    │◄──►│ scanner.lua  │      │ ui/*         │
 │ 控制面       │    │ 只读查询面    │      │ 表现面        │
 └──────┬──────┘    └──────────────┘      └──────┬───────┘
        │                                        │
        └────────────► utils.lua ◄───────────────┘
```

| 模块                  | 行数 | 职责            | 关键点                                                                                                            |
| --------------------- | ---: | --------------- | ----------------------------------------------------------------------------------------------------------------- |
| `init.lua`            |  138 | 门面 / 公共 API | `setup` 只存 UI 配置并建 `:Resonance`；`load` 懒 require loader；`stats` 首次调用即冻结启动耗时                   |
| `loader/init.lua`     |  263 | 控制面核心      | `load()` 注册 spec/trigger/build，`load_now()` 负责依赖解析、`packadd`、调用 `setup`、计时、事件重放              |
| `loader/spec.lua`     |   67 | 配置归一化      | 兼容 lazy.nvim 风格（`url` / `plugin` / `config` 别名）                                                           |
| `loader/triggers.lua` |  139 | 触发器注册      | event/cmd/keys/ft 四类，函数式短路写法，`load_now` 作为回调注入                                                   |
| `loader/build.lua`    |  134 | 构建            | `PackChanged` → `git rev-parse HEAD` → hash 比对 → `vim.system("sh -c")` + semaphore(2) + `.resonance_built` 缓存 |
| `loader/dag.lua`      |  114 | 图数据 / 事件链 | `get_dag_data`、`get_replay_info`、`BufReadPre→BufRead→BufReadPost` 链路计算                                      |
| `scanner.lua`         |  188 | 只读扫描        | 优先 `vim.pack.get(info=false, offline=true)`，回退文件系统扫描；输出 **SOA 并行数组**                            |
| `ui/init.lua`         |  248 | UI 入口         | 建 buf/win，snacks → nui → 原生三级降级，键位绑定                                                                 |
| `ui/state.lua`        |  200 | 单例状态        | `pack_details`/`updates`/`expanded`，`.git` 直读，`plugin_at_cursor`                                              |
| `ui/render.lua`       |  444 | 渲染            | 模块级复用缓冲、SOA 数值循环、extmark 高亮、列表/DAG 双视图                                                       |
| `ui/actions.lua`      |  204 | 动作            | 检查更新、更新、卸载、checkout、spinner                                                                           |
| `utils.lua`           |  110 | 共用            | 名称解析、spec 归一、trigger 文案、`notify`（优先 snacks）                                                        |

---

## 2. 三条主链路

### A. 注册链路（启动期，几乎零成本）

```text
load(spec)
  → spec.parse_config        -- 就地归一（url/plugin/config → src/plugin/setup）
  → extract_names            -- 生成 pack_plugins + parsed_names
  → 写 M.specs[name] / M.plugin_triggers[name]
  → 注册 build hook + 异步 hash 检查（check_and_build）
  → triggers.register_all    -- 挂 autocmd / user command / keymap
```

此阶段不下载、不 packadd。

### B. 触发链路（首次使用）

```text
trigger 命中
  → load_now
  → 循环检查
  → 依赖 DFS（M.specs 中有则 _force_load，否则 pack_add + packadd）
  → vim.pack.add(pack_plugins)              -- 首次安装
  → 逐个 nvim_cmd('packadd')
  → config.setup()
  → 记录 scanner.load_times
  → 若为 event 触发：重放 BufRead* 链上"尚未执行过"的 autocmd
```

### C. UI 链路

```text
scanner.get_info()                     -- 同步 ~1ms，离线快路径
  → 建 buf / win（snacks → nui → open_win）
  → Pass 1: pack.get(info=false)       -- commit / url / rev
  → 每 5ms 分块读本地 .git 补齐缺失项
  → render()
  → 50ms 后 Pass 2: pack.get(info=true) -- branches / tags
  → render()
```

---

## 3. 值得肯定的设计

1. **分层意识明确**：loader 拆成 spec/triggers/build/dag 四个正交模块，比单文件版可读性高很多。
2. **离线优先**：`vim.pack.get(info=false, offline=true)` 这条 ~0.3ms 快路径是整份代码里最有价值的性能决策；UI 打开的 ~12ms 主要靠它。
3. **两遍异步加载**（快数据先画、慢数据后补）是务实且正确的取舍，比"等全部数据再开窗"体验好一个量级。
4. **零强制依赖 + 优雅降级**：snacks / nui / 原生窗口三级回退，README 承诺与实现一致。
5. **触发器注册的函数式风格**（每个 `register_*` 先 `if not config.x then return end`）干净、易扩展。
6. **渲染层细节**：模块级复用缓冲、`table.clear`、空格缓存、SOA 数值循环、`line_to_name` 反查——确实是按 LuaJIT 思路写的。
7. **差异化的野心**：DAG 视图 + 事件重放，是 lazy.nvim 没有的东西，也是这个项目最独特的卖点。

---

## 4. 问题清单

### P1 —— 正确性缺陷（剩余未修复）

> **2026-11-17 复核：** 下表每一行都对照当前源码重新核验过。标「已修复」的行已移入
> 下方的已修复表；标「部分」的说明还剩什么。完整、可执行的清单见仓库根目录的
> `plan.md`。

| 问题                                      | 位置                                          | 说明                                                                                                                                                                                                               |
| ----------------------------------------- | --------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| **无 trigger 的 spec 永远不加载也不安装** | `triggers.register_all`                       | `load()` 只注册触发器；没有 `event/cmd/keys/ft` 就没有任何路径走到 `pack_add`。缺 `lazy=false` / eager 入口，而 `doc/resonance.txt` 还说 "load 由 setup 内部调用"，与实现不符。                                    |
| **触发器不回收**                          | `triggers.lua`                                | 一个 spec 同时有 event+cmd+keys 时，只有先触发的那个被删；`once` autocmd 之后会空转一次，keymap 残留成"删除→重放"闭包。卸载插件后 specs/triggers 也永不清除。                                                      |
| **`_plugin_dir_cache` 永不失效**          | `loader/init.lua:129`                         | 首次 `pack.add` 新装的插件不在缓存里，`get_plugin_dir` 返回 nil（`PackChanged` 因带 `data.path` 侥幸绕过）。缓存只在 `M._reset()` 里清空，从不在 `PackChanged` 时失效。                                                    |
| **UI 状态陈旧**                           | `actions.lua` / `ui/init.lua`                 | **部分已修复**：`check_updates_network` 现在会清空 `updates`（`actions.lua:57`），但 `pending_count` 没清（spinner 计数会累加）；`pack_details` / `expanded` 在 `open()` 里仍不复位。                                                   |
| **`r` 键重复触发时通知刷屏**（2026-11-17 用户报告） | `ui/init.lua:46-50`                  | 重入保护在 `actions.check_updates_network()` 内部，而通知写在 keymap 里、位于保护之外；该函数无返回值，keymap 无从判断，于是每按一次都弹一条 "Resonating in background..."。实测按 3 次弹 3 条。期望：只通知一次，且检查期间 `r` 失效。 |

### P1 —— 已修复 (2026-10-19 至 2026-10-22)

| 问题                                      | 修复 Commit | 说明                                                                                                                     |
| ----------------------------------------- | ----------- | ------------------------------------------------------------------------------------------------------------------------ |
| `pack_add_safe` 吞掉第二个参数            | a73de6d     | 改用 `...` 透传 opts，修复 `confirm/load` 默认值问题                                                                     |
| 循环依赖检测是死代码                      | aeafd81     | 在处理依赖前标记 `visiting_path`，递归 A→B→A 可被检测                                                                    |
| 依赖名解析与自定义 `name` 不兼容          | ceb610a     | 新增 `M.spec_urls` 映射 (URL -> spec name)，正确解析自定义名称                                                           |
| 重放会漏掉未分组的 autocmd                | ab2e48d     | `exclude` 非空时，无 group 的 autocmd 使用空字符串 `''` 作为键，不再整体跳过                                            |
| 固定 64KB 读取                            | b40a149     | 使用 `uv_fs_fstat` 获取文件大小，读取完整文件内容                                                                        |
| DAG 重放信息丢失 autocmd group 名称        | 6f5b0d3     | `get_replay_info()` 恢复显示 autocmd group 名称                                                                          |

### P1 —— 已修复 (2026-11-17)

| 问题                                      | 修复 Commit | 说明                                                                                                                     |
| ----------------------------------------- | ----------- | ------------------------------------------------------------------------------------------------------------------------ |
| `replay_for_buffer` 饿死迟注册的 trigger  | 38375de     | 改为按 **trigger group** 记录已触发状态，而非按事件；`nvim <file>` / yazi 打开时状态栏、bufferline、面包屑不再缺失 |
| 9 个 replay 测试空跑（断言从未执行）       | 38375de     | 补上 `test.stub_pack()` 并断言 `setup` 确实执行过；正反两个方向都做过 mutation 验证                                  |

### P2 —— 架构与可维护性

- **循环依赖 + 反向依赖**：`scanner → loader`（只为取 `plugin_triggers`）与 `loader → scanner`（只为写 `load_times`）；`ui/render → resonance`（`stats`）→ `scanner → loader`。缺一个中立的 `registry` 层，导致"打开一个只读面板"会把整个控制面（含 build autocmd）拖进来。
- **require 期副作用**：`loader/init.lua:30,89` 在模块加载时计算 `pack_dir_base`、注册 `PackChanged` augroup；`build.lua:16` 更是在 require 期就崩。模块应保持纯加载。
- **"不修改用户 spec"的注释已失效**：`config._force_load = ...`、`config._replay_done = true` 仍写回用户表；`spec.parse_config` 也就地改 `config`（`spec.lua:18-40`）。`note/knowledge` 里写的 "fixed" 已不成立。
- **`load_now` 是上帝函数**：循环检测、依赖、安装、`packadd`、setup 调用、计时、重放全在 ~100 行闭包里；`current_name = parsed_names[1]` 让多插件 spec 的依赖/环检测语义含糊；几乎无法单测。
- **重复与死代码**：`is_plugin_list` 判断写了两份（`init.lua:96` / `spec.lua:8`）；scanner 排序逻辑复制两遍；`utils.is_windows`、`scanner.get_detailed_info`、`rev_to` / `manifest` 均无消费者；`loader._get_event_chain_internal(event)` 包装丢掉 buf/data。
- **测试已有，但 CI / 格式化 / 静态检查仍缺**：2026-11-17 复核——仓库现有 13 个测试文件、197 个用例全部通过，"零测试"的说法已过时。仍缺 CI、`stylua` / `luacheck` 配置，以及 `:checkhealth`。
- **`M.stats()` 永久冻结 + `M._reset()` 不存在**（2026-11-17 新增）：`init.lua:116-133` 首次调用就把 `count` / `loaded` 整表缓存；`test/runner.lua` 调用的 `resonance._reset()` 在 `resonance/init.lua` 里根本没有（只有 `loader/init.lua` 和 `ui/state.lua` 有）。
- **`test/build_spec.lua` 存在假阳性**（2026-11-17 新增）：`build_spec.lua:28-42`（`check_and_build: skips when hash matches`）断言 `built == false` 之后立刻返回，没有 `vim.wait()`，异步的 `git rev-parse` 根本还没跑——测试通过与否与被测逻辑无关。
- **文档漂移**（影响面最大的一类问题，2026-11-17 复核）：
  - ~~README bootstrap 用了 `Vim.fn/Vim.uv/Vim.notify/Vim.system`~~ —— **已过时**，当前 README 零匹配；
  - ~~`note/` 写 DAG 键是 `g`~~ —— **已过时**，`doc/resonance.txt:224` 已经写 `A`；
  - `doc/resonance.txt:273` 说 `open_ui([ui_config])` 可覆盖配置，代码忽略参数（`init.lua:162-164`）—— **仍然成立**；
  - `doc/resonance.txt:108` 说 `resonance.setup()` 接受插件列表，实际只接受 UI 配置（`init.lua:69-74`）；Quick Start（`doc/resonance.txt:68-100`）整段示例都传错了 —— **仍然成立**；
  - `doc/resonance.txt:168` 说 `lazy = true` "Cannot combine with explicit event/cmd/keys/ft"，而 `spec.lua:44-48` 实际是把 `VeryLazy` **追加**成额外 trigger，`README.md:181` 也写对了 —— **两个文件自相矛盾**；
  - `doc/resonance.txt` Section 7 列出的 `ResonanceLoad` / `ResonanceUpdate` / `ForceLoad<Name>` 事件在源码里不存在 —— **仍然成立**；

### P2 —— 已修复 (2026-10-22)

| 问题                          | 修复 Commit | 说明                                                               |
| ----------------------------- | ----------- | ------------------------------------------------------------------ |
| UI 关键元素缺失               | d54acf9     | 恢复了被误删的 UI 关键渲染元素                                     |
| 重复代码清理                  | a7d89d3     | `dag.lua`、`spec.lua`、`utils.lua` 去重                           |
| 排序逻辑去重                  | 2956e47     | `scanner.lua`、`utils.lua` 统一排序实现                            |
| `load_now` 闭包内存泄漏       | af09a7e     | `dag.lua`、`init.lua` 修复闭包引用导致的内存泄漏                   |

### P3 —— 性能与体验

> **2026-11-17 复核：** 标注「已过时」的行已删除或划掉，其余行仍成立。

- ~~**`r` 键"网络检查"阻塞主线程**~~ —— **已过时**。`check_updates_network()` 现在走 `vim.async` + 信号量，git fetch 全部非阻塞。残留问题是**通知刷屏**（见 P1 表的新行），不是阻塞。
- ~~**spinner 每 100ms 触发一次全量重绘**~~ —— **已过时**。`render.lua:494-522` 的 `update_spinner()` 只重写一行和两个 extmark。
- **首次触发可能现场 clone**：安装被推迟到 trigger 时，第一次按键可能同步执行 `vim.pack.add`（`pack.txt` 明确"安装并行但会等待完成"），出现按键卡顿；lazy.nvim 是在启动后后台安装来规避。**注：2026-11-17 已确认这是刻意设计** —— `note/knowledge/plan-2026-11-17.md` item 4 说明安装必须保持阻塞，否则 `setup()` 会在插件落盘前执行。
- **`check_and_build` 无并发上限**：启动时每个带 build 的插件都会立刻 `async.run` 一次 `git rev-parse`，semaphore 只护住了真正的构建。
- **`.resonance_built` 写在插件目录内**（`build.lua:25`）：污染插件 git 工作区，应放 `stdpath('state')`。
- **UI 小问题**：`dd` 这类双键映射配 `nowait` 会让单独按 `d` 等待 `timeoutlen`；`cmd` 触发器桩命令用 `nargs='*'` + `complete='file'`，与真实命令签名不符时会误报错。

### P0 —— 会直接崩，且已实测复现 (0.12 不支持，决策不修复)

| 问题                                      | 位置                                          | 说明                                                                                                                                                                                                               |
| ----------------------------------------- | --------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| **`vim.async` 硬依赖，require 期无守卫**  | `loader/build.lua:10,16-17`                   | 在模块加载时就执行 `async.wrap(...)`。`nvim 0.12.6`（stable）实测：`require('resonance.loader')` → `attempt to index local 'async' (a nil value)`。本项目要求 0.13+，**决策不修复**。                               |

---

## 6. 建议的修复顺序

> **2026-11-17：** 本节已过时 —— 其中多项已完成。执行顺序以仓库根目录的
> `plan.md` 为准。保留原文仅供对照。

1. **P1 剩余项**：`_plugin_dir_cache` 失效挂到 `PackChanged`；触发器回收机制；无 trigger spec 的 eager 加载入口；UI 状态自洽刷新。
2. **P2 架构**：拆分 `load_now` 为 `resolve_deps / ensure_installed / activate / replay`；引入中立 `registry` 层打破 `scanner↔loader` 环；require 期副作用延迟到首次调用；补齐测试/CI/checkhealth。
3. **P3 体验**：`r`/`U` 改用 `vim.system` 异步链（或 `vim.async` 协程），仅重绘 spinner 行；后台预安装机制；`.resonance_built` 迁移到 `stdpath('state')`。
4. **文档同步**：README `Vim.*` → `vim.*`；`doc/resonance.txt` DAG 键 `g` → `A`；`open_ui` 参数生效；`setup` vs `load` 文档修正。
5. **工程化**：plenary / busted 测试 `spec.parse_config` + 依赖加载状态机 + 触发器清理；stylua / luacheck + CI。

### 2026-11-17 状态对照

| 原建议项 | 状态 |
|---|---|
| 测试补齐 | **已完成** —— 13 个测试文件，197 个用例全绿 |
| `r` 键异步化 | **已完成** —— `vim.async` + 信号量 |
| 仅重绘 spinner 行 | **已完成** —— `update_spinner()` 只写一行 |
| README `Vim.*` → `vim.*` | **已完成** —— 当前 README 零匹配 |
| DAG 键 `g` → `A` | **已完成** —— `doc/resonance.txt:224` 已是 `A` |
| `_plugin_dir_cache` 挂 `PackChanged` | **仍待办** |
| 触发器回收机制 | **仍待办** |
| 无 trigger spec 的 eager 入口 | **仍待办** |
| UI 状态自洽刷新 | **仍待办**（`pending_count` / `pack_details` / `expanded`） |
| 拆分 `load_now`、引入 `registry` 层 | **仍待办** |
| require 期副作用延迟 | **仍待办** |
| `open_ui` 参数生效 | **仍待办** —— 文档写错了，代码其实是对的，应改文档 |
| `setup` vs `load` 文档修正 | **仍待办** |
| CI / stylua / luacheck / checkhealth | **仍待办** |

---

## 附录：复现实验记录

环境：本机 `nvim 0.13.0-dev`，`nvim --headless -u NONE -c "set rtp+=." ...`

| 实验            | 命令要点                                          | 结果                                                                                       |
| --------------- | ------------------------------------------------- | ------------------------------------------------------------------------------------------ |
| 加载 loader     | `pcall(require,'resonance.loader')`               | **OK** (0.13+ 有 `vim.async`)                                                              |
| 打开 UI         | `pcall(require('resonance.ui').open, {})`         | **OK**                                                                                     |
| 能力探测        | `type(vim.pack), type(vim.async)`                 | `table, table`（0.13+ 均存在）                                                             |
| 循环依赖        | 注册 A↔B 后手动 `_force_load()`                   | **正确通知**: `Circular dependency detected: A -> B -> A (aborting)`                       |
| 无 trigger spec | 注册 `noop` 后检查                                | `_force_load` 存在但无任何调用路径；`plugin_triggers['noop.nvim']=nil`；未安装、未加载     |
| 依赖名不匹配    | `name='bbb'` 的 spec 以 `.../bbb.nvim` 作依赖     | **已修复**：通过 `M.spec_urls` 正确解析到 `bbb`                                            |

> 注：P0 (`vim.async`) 在 0.13+ 已不复现，项目定位 0.13+，**不再作为阻断项**。
