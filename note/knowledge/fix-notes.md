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
>
> **2026-11-18 复核：** 新增 P4「构建系统」一节（4 行，含已敲定的 A/B/C 三条决策）。
> 三个已实测复现的缺陷：`setup()` 抢在构建完成前跑、退出码 0 但打了 error 仍报
> "构建成功"、一次 load 起两个并发构建。方案见 `plan.md` Batch 5 / `fix.md` P4。

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
| **UI 状态陈旧**                           | `actions.lua` / `ui/init.lua`                 | **已修复**：`check_updates_network` 现在会清空 `updates`（`actions.lua:64`），`pending_count` 也会重置了；`pack_details` / `expanded` 现在 `open()` 里也复位了，重开的 UI 不再有残留的展开行，也不会拿上一轮的 branches/tags 缓存。                                                   |

> 2026-11-18：上表其余四行均已修复并移入下方已修复表。

### P1 —— 已修复 (2026-11-17, 续)

| 问题                                      | 修复 Commit | 说明                                                                                                                     |
| ----------------------------------------- | ----------- | ------------------------------------------------------------------------------------------------------------------------ |
| `r` 键重复触发时通知刷屏（用户报告）      | 7bfaabe     | 重入保护原本在 `actions.check_updates_network()` 内部，而通知写在 keymap 里、位于保护之外；该函数无返回值，keymap 无从判断，于是每按一次都弹一条 "Resonating in background..."。现在该函数返回 `boolean`（本次调用是否发起了检查），keymap 只在返回 `true` 时通知——检查期间 `r` 完全失效，既不重复通知也不排队第二次检查 |
| `check_updates_network` 泄漏 `pending_count`、对空路径执行 fetch | 7bfaabe | 每次检查前重置 `pending_count`（`ui.open()` 同步重置）；只对路径非空的插件执行 `git fetch`，不再以 `{ cwd = '' }` 启动进程 |
| 无 trigger 的 spec 永远不加载也不安装 | be50123 | 没有 `event/cmd/keys/ft` 也没有 `lazy` 的 spec 现在按 `lazy = false` 处理，在 `VimEnter` 加载；README 与 `doc/resonance.txt` 也改成了同样的说法 |
| 触发器不回收 | 3275053, 23d4071 | 一个 spec 的任一 trigger 触发后，**所有** sibling trigger 的桩都会被回收。键位桩换成真实映射而不是删除，命令桩在插件 `setup()` 之前就让位 |
| `_plugin_dir_cache` 永不失效 | 24160c7 | 缓存移到了 `registry.plugin_dirs`，`PackChanged`（install / delete）会让它失效 |
| `BufEnter` 对已存在的文件从不被重放 | be80437 | `fire_groups('BufEnter')` 已移出 `is_file` 分支，任何 buffer 都会重放它 |

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

### P1 —— 新核验 (2026-11-18)

> 下面每一行都在**已安装副本**上跑过，不是读代码猜的。完整清单见根目录 `fix.md` 的 P3 段。

| 问题                                          | 位置                          | 说明                                                                                                                                                                                                                                    |
| --------------------------------------------- | ----------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **`keys` 简写无 `rhs` 时删掉插件自己的映射** | `triggers.lua` `restore_keymap` | **已修复。** `keys = { '<leader>Tg' }` 表示"映射由插件自己定义"。插件加载后 `setup()` 建好真实映射，teardown 里的 `pcall(del_keymap, ...)` **无条件删除**它，而 `rhs` 为 nil 所以不会补回来——用户的快捷键静默失效。key 自身触发和 sibling trigger 触发两条路径都验证过：映射都是 `rhs=nil callback=nil`，即被删光。现在 teardown 先比对已安装映射的 callback 与 stub 是否同一个，只在 stub 仍在位时才删除；比 callback 而非 lhs，是因为 keymap API 用自己的记法回报 lhs（`<C-x>` 回报成 `<C-X>`）。顺带修掉三个 buffer 处理缺陷：`opts.buffer = false` 是全局映射却被当成 buffer-local、`opts.buf = 0` 在 set 与 delete 之间指向了不同的 buffer、以及 key 触发时重复 `set_keymap` |
| **`nargs = 0` 的命令触发器报 `E1208`**       | `triggers.lua` `register_cmd`  | **已修复。** 命令默认带 `complete = 'file'`，spec 把 `nargs` 覆盖成 `0` 后 Neovim 拒绝：`'complete' used without 'nargs'`。错误从 `resonance.load()` 抛出，插件根本没注册——而且比"命令没注册"更糟：错误中断了整个 `load()`，所以同一个 spec 的其他 trigger 也一个都没注册。现在 `nargs = 0` 时默认的 `complete` 会被去掉（用户自己写的 `complete` 保留） |
| **`force_load_fns` 留住用户的 `setup` 闭包** | `loader/init.lua`              | **已修复。** `retained_spec()` 不留 `setup`，但 `force_load_fns[name] = load_now` 的闭包 upvalue 仍然是 `config`，`config.setup` 因而活到会话结束。清掉 `force_load_fns` 后闭包立刻可回收——验证过。现在成员加载完成后立刻释放 `config.setup` / `config.config` 以及 `plugin` 列表里每个成员的 `setup` / `config`。释放发生在 setup 调用**之后**，所以 setup 仍然恰好跑一次 |
| **`behavior_ui_spec` 的断言恒真**            | `test/behavior_ui_spec.lua`    | **已修复。** `helpers.count(t)` 是 `#t`，而 `name_to_line` 用字符串做键，`#` 对纯字符串键表恒为 `0`。所以 `count(st.name_to_line) == 0` 无论清没清都通过——实测塞了 49 条记录，断言依然为真。旁边的 `line_to_name` 侥幸有效，但 `#` 对稀疏整数表也不是长度。现在新增 `helpers.map_count`（遍历而非取长度），两张表都用它断言 |
| **`normalize_events` 丢掉表形式 `pattern`** | `utils.lua`                    | **已修复。** 只收 `type(pattern) == 'string'`。Neovim 接受 pattern 列表，所以 `pattern = { '*.lua', '*.vim' }` 的 patterns 全丢——验证：回读得到 `pattern=nil`。现在原生事件列表和 `User` 事件都保留列表形式的 pattern，最终交给 `nvim_create_autocmd`（每个 pattern 建一个 autocmd） |
| **`fetch_plugin_details` 不取消上一个任务**  | `ui/actions.lua`               | **已修复。** `st.state.details_task = task` 直接覆盖，不取消旧的。连开两行会跑**两次** `info = true` 抓取（`detail_calls: 2`）。只是冗余，不是数据损坏：每个任务写自己的 name key。现在开新任务前先 `close` 旧的；被取消的任务报错是 `"closed"`，完成回调只在失败任务仍是当前任务时才通知，所以取消不再弹误报 |
| **`marker_path` 不清洗插件名**              | `loader/build.lua`             | **已修复。** `marker_dir .. '/' .. name`，名字里带 `/` 就写到不存在的目录，失败被静默吞掉。验证：`mark_build_success('evil/name')` 不报错但什么都没写，构建缓存丢失，每次检查都重新构建。现在名字取最后一段路径，跟 `vim.pack` 的 `name:match('[^/]+$')` 一致。除了修好缓存丢失，也堵住了路径穿越：修复前 `mark_build_success('../escaped.txt')` 会写到 `state/resonance/escaped.txt`（在 marker 目录外），修复后留在 `state/resonance/builds/` 里 |

### P2 —— 架构与可维护性

- **循环依赖 + 反向依赖**：`scanner → loader`（只为取 `plugin_triggers`）与 `loader → scanner`（只为写 `load_times`）；`ui/render → resonance`（`stats`）→ `scanner → loader`。缺一个中立的 `registry` 层，导致"打开一个只读面板"会把整个控制面（含 build autocmd）拖进来。
- **require 期副作用**：`loader/init.lua:30,89` 在模块加载时计算 `pack_dir_base`、注册 `PackChanged` augroup；`build.lua:16` 更是在 require 期就崩。模块应保持纯加载。
- **"不修改用户 spec"的注释已失效**：`config._replay_done = true` 仍写回用户表；`spec.parse_config` 也就地改 `config`（`spec.lua:18-40`）。`note/knowledge` 里写的 "fixed" 已不成立。
  - **2026-11-17 复核：** 原文还提到 `config._force_load`，但**该字段在当前源码里已不存在**（`rg '_force_load' lua/` 零匹配）。这一条是从旧版本抄过来的，没有重新核对。剩下的用户表改写只有 `_replay_done` 一处。
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
| **卸载后 build marker 没清，重装跳过构建** | `ui/actions.lua` + `loader/build.lua` | **已修复。** `uninstall_plugin()` 调了 `pack.del`、清了 UI 缓存，但没删 build marker。marker 在 `stdpath('state')/resonance/builds`，比插件活得久。构建产物在插件目录里，卸载时一起没了；重装同版本落在同一个 commit 上，`check_and_build()` 看到 `last_hash == curr_hash` 就提前返回，**构建被跳过，插件重装后没有产物**：`flash-any.nvim` 缺 `native.so`，`markdown-preview2.nvim` / `telegram.nvim` 缺 `node_modules`。现在卸载会一起删 marker |
| **`vim.async` 在启动时被急切加载** | `loader/build.lua` | **已修复。** `build.lua` 在模块层 `local async = vim.async`，而 loader 在 setup 时就 require 它，于是每次启动都要付 `vim.async` 及其 7 个子模块的加载代价。实测 `vim.async` 加载要 **1.4 ms**；loader 的 require 是 1.69 ms，预加载 `vim.async` 后只要 0.03 ms。现在 async 机制改成首次使用时才建，启动时间 8.44 ms → **6.80 ms** |
| **`vim.async` 硬依赖，require 期无守卫**  | `loader/build.lua:10,16-17`                   | 在模块加载时就执行 `async.wrap(...)`。`nvim 0.12.6`（stable）实测：`require('resonance.loader')` → `attempt to index local 'async' (a nil value)`。本项目要求 0.13+，**决策不修复**。 （注：上面的急切加载问题已单独修掉，现在 `async.wrap` 也是首次使用时才建）                               |

### P4 —— 构建系统（2026-11-18，方案已定，尚未实现）

| 问题 | 位置 | 说明 |
| --- | --- | --- |
| **`setup()` 抢在构建完成前跑** | `loader/init.lua` + `loader/build.lua` | 加载流程是 `pack_install` → `:packadd` → `setup()`，全同步；构建是之后靠 `PackChanged` 才异步开始的。实测时间线：`1. build START` → `2. setup() ran; artifact exists = false`（早了 2 秒）。插件在半成品目录上初始化，`markdown-preview2.nvim` 的 node server 缺 `socket.io-client` 直接挂掉；server 又注册了 `process.on("uncaughtException")` 回调 Neovim，于是连 `:qa` 路径都在报错（截图里的 `closeAllPages`） |
| **构建退出码为 0 但打了 error，仍报"构建成功"** | `loader/build.lua` | 只看退出码。命令往 stderr 打了 error 但 `exit 0`，就被判成功，**marker 也写了**，以后再也不重建。用户看到的正是"先 npm error，再 Build succeeded" |
| **一次 load 起了两个构建** | `loader/build.lua` | `check_and_build()` 有两个调用点：loader 注册 hook 时一次，`PackChanged` 安装时又一次。第二次在第一次还在跑时又起一个，并发写同一个目录，还弹两条 "Build succeeded" |
| **缺一个构建状态查询 API** | 新增 `lua/resonance/builds.lua` | 方案已与用户敲定（详见 `plan.md` Batch 5 item 30 / `fix.md` P4 item 30）：<br>· **A 决策**：后台构建**永不阻塞**编辑器。只有用户主动按键/敲命令才等待，且等待要可 `<C-c>` 中断（只中断等待，不杀后台构建）；`event`/`ft`/`VimEnter`/`VeryLazy` 触发的加载**延后**到构建完成再 `setup()`。<br>· **B 决策**：只看 `exit code ~= 0` 判失败，**stderr 非空不算失败**（`yarn`/`npm`/`cargo`/`make` 成功时也往 stderr 写 warning）；stdout/stderr 尾部收进 `output_tail` 展示，让被吞掉的错误可见。<br>· **C 决策**：**双超时** —— 提示阈值（3–5s，超过才提示"仍在构建"）和构建硬超时（10min，超时杀子进程、标记 failed、**不写 marker**，下次重试）；`wait()` 自己的超时与 `<C-c>` **不杀**后台构建。跨会话锁文件存**子进程 PID**，用 `vim.uv.kill(pid, 0)` 探活防止死锁；还要防"孤儿陷阱" —— session 被 kill 后 Lua VM 死了，孤儿构建跑完但 `on_complete` 永不触发，marker 和锁文件都没人清，所以下一个 session 发现 PID 已不在（`ESRCH`）且 marker 缺失时**允许重建**（重跑 `yarn install` 对已建好的树很快，能补上 marker） |

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
| 测试补齐 | **已完成** —— 19 个测试文件，268 个用例全绿 |
| `r` 键异步化 | **已完成** —— `vim.async` + 信号量 |
| 仅重绘 spinner 行 | **已完成** —— `update_spinner()` 只写一行 |
| README `Vim.*` → `vim.*` | **已完成** —— 当前 README 零匹配 |
| DAG 键 `g` → `A` | **已完成** —— `doc/resonance.txt:224` 已是 `A` |
| `_plugin_dir_cache` 挂 `PackChanged` | **已完成** —— 缓存移到 `registry.plugin_dirs`，`PackChanged` 时失效（item 13） |
| 触发器回收机制 | **已完成** —— load 后所有兄弟触发器桩一起回收（item 8） |
| 无 trigger spec 的 eager 入口 | **已完成** —— 无 trigger 的 spec 默认 `lazy = false`（`VimEnter`）加载（item 3） |
| UI 状态自洽刷新 | **已完成**（`pending_count` / `pack_details` / `expanded` 都会复位） |
| 拆分 `load_now`、引入 `registry` 层 | **已完成** —— `registry.lua` 已加，`scanner↔loader` 环已打破（item 14） |
| require 期副作用延迟 | **已完成** —— autocmd / event tracker 改成首次调用时才装（item 14） |
| `open_ui` 参数生效 | **已完成** —— 代码本来就不收参数（用 `setup()` 里的 `ui` 配置），文档已写对 |
| `setup` vs `load` 文档修正 | **已完成** —— `doc/resonance.txt:107` 已写明 "`setup()` takes only the UI options... Plugin specifications go to `load()`" |
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
