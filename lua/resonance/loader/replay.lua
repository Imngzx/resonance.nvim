-- Event replay: which read events and trigger groups have already run for a
-- buffer, and re-firing the ones a lazily loaded plugin missed.
local M = {}

local api = vim.api
local uv = vim.uv

local get_autocmds = api.nvim_get_autocmds
local exec_autocmds = api.nvim_exec_autocmds
local pcall = pcall

-- Guards against recursive event replay. Replaying an event re-fires the
-- autocmds for it, which can re-enter load_now and start another replay.
-- Per-plugin `replay_done` is not enough: two plugins on the same event
-- replay each other indefinitely.
local replay_depth = 0
local MAX_REPLAY_DEPTH = 2

-- Events that have already fired, per buffer. The replay must not re-fire an
-- event that has already run for the buffer being loaded: a handler that
-- opens a file would recurse until Neovim aborts with E218.
--
-- Keyed by buffer so that a mark from an earlier read does not suppress the
-- events still pending for the current one.
local fired_events = {}

-- Which trigger groups have already run for a buffer.
--
-- The per-event table above answers "has this event fired for this buffer?".
-- That is the wrong question for a trigger: a group registered AFTER the
-- event fired has not seen the event yet, even though the event is in the
-- past. Tracking the groups separately lets the replay give a late-registered
-- trigger its chance, while still skipping the groups that already ran.
--
-- Keyed by buffer, then by group name.
local fired_groups = {}

-- Keyed by buffer id. The GC suite checks that a wiped buffer leaves no key
-- behind: the heap cannot tell, because Neovim's own runtime retains more
-- per buffer than these tables do.
M.fired_events = fired_events
M.fired_groups = fired_groups

-- BufRead and BufReadPost are aliases in Neovim: an autocmd registered for
-- one fires for the other, and get_autocmds matches them together. The
-- tracker only registers BufReadPost, so map BufRead onto it.
local function event_fired_key(event)
  if event == 'BufRead' then return 'BufReadPost' end
  return event
end

local function has_fired(event, buf)
  local per_buf = fired_events[buf]
  if not per_buf then return false end
  return per_buf[event_fired_key(event)] == true
end

local function mark_fired(event, buf)
  local per_buf = fired_events[buf]
  if not per_buf then
    per_buf = {}
    fired_events[buf] = per_buf
  end
  per_buf[event_fired_key(event)] = true
end

-- Whether a trigger group has already run for a buffer.
local function group_has_fired(group_name, buf)
  if not group_name then return false end
  local per_buf = fired_groups[buf]
  if not per_buf then return false end
  return per_buf[group_name] == true
end

-- Record that a trigger group has run for a buffer.
local function mark_group_fired(group_name, buf)
  if not group_name then return end
  local per_buf = fired_groups[buf]
  if not per_buf then
    per_buf = {}
    fired_groups[buf] = per_buf
  end
  per_buf[group_name] = true
end

M.mark_group_fired = mark_group_fired

-- Record which events have fired, per buffer. The replay uses this to avoid
-- re-firing an event that already ran for the buffer being loaded: when a
-- plugin loads on BufReadPre, BufRead and BufReadPost are still to come for
-- the same read and will fire naturally.
--
-- Note: nvim_create_autocmd('BufRead') registers a BufReadPost autocmd (the
-- two are aliases), so BufRead is tracked via BufReadPost.
local TRACKED_EVENTS = { 'BufReadPre', 'BufReadPost', 'BufNewFile', 'BufEnter', 'FileType' }
local tracker_group = nil
local function setup_event_tracker()
  tracker_group = api.nvim_create_augroup('ResonanceEventTracker', { clear = true })
  for i = 1, #TRACKED_EVENTS do
    local name = TRACKED_EVENTS[i]
    api.nvim_create_autocmd(name, {
      group = tracker_group,
      callback = function(args)
        mark_fired(name, args.buf)
        -- Mark every trigger group that existed when this event fired: they
        -- have seen the event, so the replay must not fire them again.
        --
        -- A group registered AFTER the event is not marked here, which is
        -- exactly what lets a late-registered trigger still load.
        local autocmds = get_autocmds({ event = name })
        for a = 1, #autocmds do
          local autocmd = autocmds[a]
          if autocmd.event == name and autocmd.group_name then
            mark_group_fired(autocmd.group_name, args.buf)
          end
        end
      end,
    })
  end

  -- The fired state is keyed by buffer id, so it has to be pruned when a
  -- buffer goes away. Without this, every buffer a user ever opened stayed
  -- in the tables for the whole session.
  api.nvim_create_autocmd('BufWipeout', {
    group = tracker_group,
    callback = function(args)
      fired_events[args.buf] = nil
      fired_groups[args.buf] = nil
    end,
  })
end

-- The event tracker is installed on first use, not when the module is
-- required. Requiring the loader used to install five autocmds and a
-- BufWipeout handler as a side effect, which meant that anything that
-- merely touched the loader paid for a control plane it did not ask for.
function M.ensure_tracker()
  if tracker_group then return end
  setup_event_tracker()
end

-- Whether an event has already fired for a buffer.
--
-- A user config that replays missed events can use this to skip the events
-- that already ran, instead of firing them a second time.
---@param event string
---@param buf integer
---@return boolean
function M.has_fired(event, buf)
  if not event or not buf then return false end
  M.ensure_tracker()
  return has_fired(event, buf)
end

-- Replay the read events a buffer has already missed.
--
-- Fires only the trigger groups that have not yet run for the buffer, so a
-- handler is not invoked twice for the same read. Events that are still
-- pending for the current read are left alone: Neovim fires them naturally.
--
-- The unit of "already ran" is the trigger group, not the event. A group
-- registered after the event already fired has not seen it yet, and must
-- still get its chance to load: that is the `nvim <file>` path, where
-- BufReadPost and BufEnter fire before UIEnter -> VeryLazy, and the UI
-- plugins register their triggers in VeryLazy.
---@param buf integer
---@return string[] fired the events that were replayed
function M.replay_for_buffer(buf)
  local fired = {}
  if not buf then return fired end
  if not api.nvim_buf_is_valid(buf) then return fired end
  M.ensure_tracker()
  local api_exec = exec_autocmds

  -- A buffer with a name that exists on disk was read; one without was
  -- created new.
  local name = api.nvim_buf_get_name(buf)
  local is_file = false
  if name ~= '' then
    local stat = uv.fs_stat(name)
    is_file = stat ~= nil and stat.type == 'file'
  end

  -- Fire one event once per trigger group that has not run for this buffer.
  --
  -- Firing the whole event would re-run the groups that already saw it,
  -- which is what caused the duplicate handlers and the E218 recursion. So
  -- the event is fired once per pending group, scoped to that group.
  local function fire_groups(event)
    local autocmds = get_autocmds({ event = event })
    local done = {}
    local any = false
    for a = 1, #autocmds do
      local autocmd = autocmds[a]
      -- get_autocmds matches BufRead and BufReadPost together, so filter to
      -- the event actually being replayed.
      if autocmd.event == event then
        local group_name = autocmd.group_name
        if group_name and not done[group_name] and not group_has_fired(group_name, buf) then
          done[group_name] = true
          mark_group_fired(group_name, buf)
          api_exec(event, { buf = buf, group = group_name, modeline = false })
          any = true
        end
      end
    end
    if any then fired[#fired + 1] = event end
  end

  -- The is_file split decides between the events that genuinely differ for
  -- an existing file versus a new one. BufEnter fires for every buffer, so
  -- it is replayed either way -- putting it in the "not a file" branch left
  -- a BufEnter-only trigger group permanently unreplayed on the
  -- `nvim <file>` path.
  if is_file then
    fire_groups('BufReadPre')
    fire_groups('BufReadPost')
  else
    fire_groups('BufNewFile')
  end

  fire_groups('BufEnter')
  fire_groups('FileType')

  return fired
end

-- Re-fire, for the buffer of the event that just loaded a plugin, the
-- events of its chain that already fired, so the freshly loaded plugin's
-- own handlers get to see them.
---@param ev table the event that triggered the load
function M.after_load(ev)
  -- A replay re-fires autocmds, which can re-enter load_now. Bound the
  -- nesting so a plugin whose handler triggers the same event cannot
  -- recurse until Neovim aborts with E218.
  if replay_depth >= MAX_REPLAY_DEPTH then return end

  -- Only replay events that have already fired for this buffer. When a
  -- plugin loads from BufReadPre, Neovim still has BufRead and BufReadPost
  -- to fire for this same read; replaying them here would run them twice,
  -- and a handler that opens a file (snacks picker, for one) would recurse
  -- until Neovim aborts with E218.
  --
  -- The check is per buffer: a mark left by an earlier read must not
  -- suppress the events still pending for the current one.
  local origin_event = event_fired_key(ev.event)
  if not has_fired(ev.event, ev.buf) then
    -- The trigger is the first event of its group, so nothing has fired
    -- yet and there is nothing to replay.
    return
  end

  -- Required here, not at the top: the DAG module is not needed on the
  -- startup path, and this runs only after a triggered load.
  local chain = ev.event ~= 'User' and
    require('resonance.loader.dag')._get_event_chain_internal(ev.event, ev.buf, ev.data) or {}
  replay_depth = replay_depth + 1
  local replay_ok, replay_err = pcall(function()
    for c = 1, #chain do
      local c_opts = chain[c]
      -- Skip the origin event: it is the one currently being handled.
      -- Skip events that have not fired for this buffer yet: they will
      -- fire naturally.
      if event_fired_key(c_opts.event) ~= origin_event and has_fired(c_opts.event, ev.buf) then
        local autocmds = get_autocmds({ event = c_opts.event })
        local done = {}
        for a = 1, #autocmds do
          local autocmd = autocmds[a]
          -- get_autocmds matches BufRead and BufReadPost together, so
          -- filter to the event actually being replayed.
          if autocmd.event == c_opts.event then
            local group_name = autocmd.group_name
            -- Ungrouped autocmds cannot be selected individually, and
            -- firing the whole event would re-run the autocmd we are
            -- executing. Only grouped autocmds can be replayed safely.
            if group_name and not c_opts.exclude[group_name] and not done[group_name] then
              done[group_name] = true
              exec_autocmds(c_opts.event,
                { buf = c_opts.buf, group = group_name, modeline = false, data = c_opts.data })
            end
          end
        end
      end
    end
  end)
  replay_depth = replay_depth - 1
  if not replay_ok then error(replay_err) end
end

-- Reset the fired state (for testing). The tracker autocmds stay installed:
-- reinstalling them would create a second copy of every handler.
function M._reset()
  for k in pairs(fired_events) do fired_events[k] = nil end
  for k in pairs(fired_groups) do fired_groups[k] = nil end
  replay_depth = 0
end

return M
