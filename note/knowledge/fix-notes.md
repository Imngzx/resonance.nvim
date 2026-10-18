# Resonance.nvim 架构梳理与评析

> 评审对象：`resonance.nvim`（约 2250 行 Lua，`lua/resonance/` 下 11 个模块）
> 评审日期：2026-10-17
> 评审环境：Neovim **0.12.6**（LuaJIT 2.1），仓库根目录直接入 `rtp` 做 headless 实测
> 说明：本文是架构快照，结论基于当时的 `HEAD`（`c673fbb`）。带「实测」标记的结论均已在本机复现。

---

## 1. 定位与分层

一句话：**`vim.pack`（Neovim 原生包管理）之上的一层"懒加载 + 构建钩子 + 管理面板"薄壳**，自己不做下载、不做锁文件、不做版本解析，全部委托给 `vim.pack.add/get/update/del`。

代码分五层：

```
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

```
load(spec)
  → spec.parse_config        -- 就地归一（url/plugin/config → src/plugin/setup）
  → extract_names            -- 生成 pack_plugins + parsed_names
  → 写 M.specs[name] / M.plugin_triggers[name]
  → 注册 build hook + 异步 hash 检查（check_and_build）
  → triggers.register_all    -- 挂 autocmd / user command / keymap
```

**此阶段不下载、不 packadd。**

### B. 触发链路（首次使用）

```
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

```
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

### P0 —— 会直接崩，且已实测复现

- **`vim.async` 硬依赖，require 期无守卫**（`loader/build.lua:10,16-17`）
  在模块加载时就执行 `async.wrap(...)`。本机 `nvim 0.12.6`（stable）实测：
  - `require('resonance.loader')` → `attempt to index local 'async' (a nil value)`
  - 连带 `scanner.get_info()`（`scanner.lua:94` require loader）和 `ui.open()` 全部失败。
  - 也就是说 README 的 bootstrap 片段在 0.12 上 **100% 不可用**，而文档只在标题里写了 "0.13+"，没有任何运行时检查或提示。
- **建议**：能力探测 + 回调版 `vim.system` 回退；`scanner` 不 require loader；提供 `:checkhealth resonance` 明确报版本。

### P1 —— 正确性缺陷（部分已实测）

| 问题                                      | 位置                                          | 说明                                                                                                                                                                                                               |
| ----------------------------------------- | --------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| **循环依赖检测是死代码**                  | `loader/init.lua:147-172`                     | `visiting_path[current_name]` 只被读、被清，**从未被置 true**，`path_order` 也从未 append。实测 A↔B：两个都 loaded，**零条 "Circular dependency" 通知**。真正让它不爆栈的是 `state.loaded = true` 的早退。         |
| **`pack_add_safe` 吞掉第二个参数**        | `loader/init.lua:12-14`                       | `function pack_add_safe(vararg)` 是单参（不是 `...`），`pcall(pack_add_safe, specs, {confirm=false, load=false})` 里的 opts **永远丢失**。后果：`confirm` 保持默认 true，运行期 `load` 默认 true，与代码意图相反。 |
| **依赖名解析与自定义 `name` 不兼容**      | `utils.lua:45-48` + `loader/init.lua:177-184` | `dependencies = {'.../bbb.nvim'}` 得到 `bbb.nvim`，若 spec 写了 `name='bbb'` 就匹配不到 `M.specs`，退回 `packadd 'bbb.nvim'` 失败——且 `pcall` 静默，用户只看到"插件没生效"。                                       |
| **无 trigger 的 spec 永远不加载也不安装** | `triggers.register_all`                       | `load()` 只注册触发器；没有 `event/cmd/keys/ft` 就没有任何路径走到 `pack_add`。缺 `lazy=false` / eager 入口，而 `doc/resonance.txt` 还说 "load 由 setup 内部调用"，与实现不符。                                    |
| **重放会漏掉未分组的 autocmd**            | `loader/init.lua:222-236`                     | `exclude` 非空时只重放 `autocmd.group` 为真的项，**无 group 的 autocmd 被整体跳过**；且链路只覆盖 `BufReadPre/BufNewFile→BufRead→BufReadPost`。                                                                    |
| **触发器不回收**                          | `triggers.lua`                                | 一个 spec 同时有 event+cmd+keys 时，只有先触发的那个被删；`once` autocmd 之后会空转一次，keymap 残留成"删除→重放"闭包。卸载插件后 specs/triggers 也永不清除。                                                      |
| **`_plugin_dir_cache` 永不失效**          | `loader/init.lua:35-79`                       | 首次 `pack.add` 新装的插件不在缓存里，`get_plugin_dir` 返回 nil（`PackChanged` 因带 `data.path` 侥幸绕过）。                                                                                                       |
| **固定 64KB 读取**                        | `state.lua:147,160`                           | `.git/packed-refs` 超过 64KB 被截断，hash 解析失败 → `unknown`。                                                                                                                                                   |
| **UI 状态陈旧**                           | `actions.lua:99-147`                          | update/uninstall 后不刷新 `st.state.info`；`check_updates_network` 不先清空 `updates`（远端回退后仍显示旧 pending）；`pack_details` / `expanded` 在 `open()` 里不复位。                                            |

### P2 —— 架构与可维护性

- **循环依赖 + 反向依赖**：`scanner → loader`（只为取 `plugin_triggers`）与 `loader → scanner`（只为写 `load_times`）；`ui/render → resonance`（`stats`）→ `scanner → loader`。缺一个中立的 `registry` 层，导致"打开一个只读面板"会把整个控制面（含 build autocmd）拖进来。
- **require 期副作用**：`loader/init.lua:30,89` 在模块加载时计算 `pack_dir_base`、注册 `PackChanged` augroup；`build.lua:16` 更是在 require 期就崩。模块应保持纯加载。
- **"不修改用户 spec"的注释已失效**：`config._force_load = ...`、`config._replay_done = true` 仍写回用户表；`spec.parse_config` 也就地改 `config`（`spec.lua:18-40`）。`note/knowledge` 里写的 "fixed" 已不成立。
- **`load_now` 是上帝函数**：循环检测、依赖、安装、`packadd`、setup 调用、计时、重放全在 ~100 行闭包里；`current_name = parsed_names[1]` 让多插件 spec 的依赖/环检测语义含糊；几乎无法单测。
- **重复与死代码**：`is_plugin_list` 判断写了两份（`init.lua:96` / `spec.lua:8`）；scanner 排序逻辑复制两遍；`utils.is_windows`、`scanner.get_detailed_info`、`rev_to` / `manifest` 均无消费者；`loader._get_event_chain_internal(event)` 包装丢掉 buf/data。
- **零测试、零 CI、无格式化/静态检查配置**（只有 `.editorconfig` 和 `.markdownlint.json`），也没有 `:checkhealth`。这类"状态机 + 异步 + 自动命令"的代码不测几乎必然回归。
- **文档漂移**（影响面最大的一类问题）：
  - README bootstrap 用了 `Vim.fn/Vim.uv/Vim.notify/Vim.system`（`README.md:36-46`），实际应为 `vim.*`；
  - `doc/resonance.txt:198` 与 `note/` 写 DAG 键是 `g`，代码是 `A`（`ui/init.lua:97`）；
  - `doc` 说 `open_ui([ui_config])` 可覆盖配置，代码忽略参数（`init.lua:132`）；
  - `doc` 说 `resonance.setup()` 接受插件列表，实际只接受 UI 配置；
  - `AGENTS.md` 全是 `/home/alice/...`，且 spinner 写"10 帧"，代码 `% 8`（`actions.lua:38`）只用到 8 帧。

### P3 —— 性能与体验

- **`r` 键"网络检查"阻塞主线程**：`actions.lua:50-89` 在 `vim.defer_fn(...,1)` 后同步调用 `vim.pack.get(info=true, offline=false)`（README 自述 ~2s+），期间编辑器完全冻结，spinner 也不动。`update_plugins` 里的 `vim.pack.update(..., {force=true, offline=false})` 同样阻塞。与 README 的 "Fast / async" 定位矛盾。
- **spinner 每 100ms 触发一次全量重绘**：`render()` 重写整个 buffer + 重建全部 extmark（每个高亮片段一个），N 个插件时是 O(N·segments) 的无效工作，而实际只变了一行。
- **首次触发可能现场 clone**：安装被推迟到 trigger 时，第一次按键可能同步执行 `vim.pack.add`（`pack.txt` 明确"安装并行但会等待完成"），出现按键卡顿；lazy.nvim 是在启动后后台安装来规避。
- **`check_and_build` 无并发上限**：启动时每个带 build 的插件都会立刻 `async.run` 一次 `git rev-parse`，semaphore 只护住了真正的构建。
- **`.resonance_built` 写在插件目录内**（`build.lua:25`）：污染插件 git 工作区，应放 `stdpath('state')`。
- **UI 小问题**：`dd` 这类双键映射配 `nowait` 会让单独按 `d` 等待 `timeoutlen`；`cmd` 触发器桩命令用 `nargs='*'` + `complete='file'`，与真实命令签名不符时会误报错。

---

## 5. 总体评价

| 维度          | 评价                                                                                        |
| ------------- | ------------------------------------------------------------------------------------------- |
| 分层与模块化  | **B**：思路对，但 `scanner↔loader` 环 + require 副作用拉低分数                              |
| 性能设计      | **B-**：快路径确实快，但"网络检查/更新"这条主交互路径是阻塞的，benchmark 只覆盖了便宜的部分 |
| 健壮性        | **C**：P0 直接崩、循环检测失效、大量裸 `pcall` 静默失败、"依赖没装上"没有任何提示           |
| 状态管理      | **C+**：单例 state + 手工同步，update/del 后不自洽                                          |
| 可维护性/文档 | **C+**：代码注释质量不错，但文档与实现多处不一致、无测试无 CI                               |
| 差异化        | **A-**：DAG 视图 + 事件重放 + 纯原生 `vim.pack` 的组合确实有想法                            |

**一句话结论**：骨架（分层、离线快路径、触发器抽象）是对的，但"最后一公里"的工程化没做——版本守卫、错误可见性、状态刷新、网络异步、测试与文档同步，这五件事补齐之前，它更像一个高完成度的个人配置组件，而不是能对外发布的插件管理器。

---

## 6. 建议的修复顺序

1. **P0 立即修**：`build.lua` 的 `vim.async` 守卫 + 回退；`scanner` 去掉对 loader 的 require；加 `:checkhealth resonance` 报版本能力。
2. **错误可见**：去掉裸 `pcall`，统一 `safe_call(label, fn, ...)`，失败时 notify（插件名 + 命令 + stderr）；`pack_add_safe` 改 `...`；缓存失效挂到 `PackChanged`。
3. **状态机拆分**：`load_now` 拆成 `resolve_deps / ensure_installed / activate / replay`；触发器改成对象 `{id, kind, cleanup}`，加载后统一清理；补 eager（`lazy=false`）、`enabled`、`cond`。
4. **事件重放重做**：按 autocmd **id 快照**去重，而不是 group 名；扩展链路或改成"重放快照中未执行过的全部匹配 autocmd"。
5. **UI 异步化**：`r` 用 `git ls-remote` / `git log` 的 `vim.system` 异步链（或 `vim.async` 可用时用协程），不要同步 `pack.get(offline=false)`；update/del 后重新 `get_info()`；只重绘 spinner 所在行。
6. **工程化**：plenary / busted 测试 `spec.parse_config` + 依赖加载状态机 + 触发器清理；stylua / luacheck + CI；同步修正 README/doc/AGENTS 的 `Vim.`、`g` vs `A`、`/home/alice`、`%8` 等漂移。

---

## 附录：复现实验记录

环境：本机 `nvim 0.12.6`，`nvim --headless -u NONE -c "set rtp+=." ...`

| 实验            | 命令要点                                          | 结果                                                                                       |
| --------------- | ------------------------------------------------- | ------------------------------------------------------------------------------------------ |
| 加载 loader     | `pcall(require,'resonance.loader')`               | `false  ./lua/resonance/loader/build.lua:16: attempt to index local 'async' (a nil value)` |
| 打开 UI         | `pcall(require('resonance.ui').open, {})`         | `false  同上（scanner.get_info → require loader）`                                         |
| 能力探测        | `type(vim.pack), type(vim.async)`                 | `table, nil`（`vim.pack` 存在但无 `vim.async`）                                            |
| 循环依赖        | 桩掉 `vim.async`，注册 A↔B 后手动 `_force_load()` | `aaa.nvim loaded=true, bbb.nvim loaded=true, 通知条数=0`                                   |
| 无 trigger spec | 注册 `noop` 后检查                                | `_force_load` 存在但无任何调用路径；`plugin_triggers['noop.nvim']=nil`；未安装、未加载     |
| 依赖名不匹配    | `name='bbb'` 的 spec 以 `.../bbb.nvim` 作依赖     | 走 `packadd 'bbb.nvim'`，`pcall` 静默失败，依赖未加载                                      |

> 注：上述"桩掉 `vim.async`"仅用于让 loader 在 0.12 上可加载，以便验证控制面逻辑；不代表修复方案本身。
