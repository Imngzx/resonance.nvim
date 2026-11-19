-- Tests for the help file: links resolve and doc/tags is current.
-- Run with: test/dev_env.sh test test/docs_spec.lua
--
-- Reads the repo's doc/ (the runner's working directory), not the
-- installed copy: the help file is checked as it will be committed.

local DOC = 'doc/resonance.txt'

local function read_lines(path)
  local f = io.open(path, 'r')
  if not f then return nil end
  local lines = {}
  for line in f:lines() do lines[#lines + 1] = line end
  f:close()
  return lines
end

-- The tag names in a tags file: the first tab-separated field of each line.
local function tag_set(path)
  local set = {}
  local lines = read_lines(path) or {}
  for i = 1, #lines do
    local name = lines[i]:match('^([^\t]+)\t')
    if name then set[name] = true end
  end
  return set
end

-- Let Neovim itself parse the help file, so the tags are the ones :help
-- will see -- no hand-rolled `*tag*` pattern to drift from the real rules.
-- helptags also fails on a duplicate tag, which this surfaces.
local function generated_tags()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, 'p')
  vim.fn.writefile(read_lines(DOC), dir .. '/resonance.txt')
  local ok, err = pcall(vim.cmd.helptags, vim.fn.fnameescape(dir))
  local lines = read_lines(dir .. '/tags') or {}
  local set = tag_set(dir .. '/tags')
  vim.fn.delete(dir, 'rf')
  return ok, err, lines, set
end

test.run_suite('resonance.docs', {

  {
    name = 'docs: helptags accepts the help file (no duplicate tags)',
    fn = function()
      local ok, err = generated_tags()
      test.assert_true(ok, 'helptags failed: ' .. tostring(err))
    end,
  },

  {
    name = 'docs: doc/tags is regenerated after a tag change',
    fn = function()
      local _, _, generated = generated_tags()
      local committed = read_lines('doc/tags') or {}
      test.assert_eq(table.concat(committed, '\n'), table.concat(generated, '\n'),
        "doc/tags is stale: run  nvim --headless -c 'helptags doc' -c q")
    end,
  },

  {
    name = 'docs: every |link| in the help file resolves to a tag',
    fn = function()
      local _, _, _, own = generated_tags()
      local builtin = tag_set(vim.env.VIMRUNTIME .. '/doc/tags')
      local lines = assert(read_lines(DOC), 'cannot read ' .. DOC)

      local broken = {}
      for i = 1, #lines do
        for name in lines[i]:gmatch('|([%w_.()%-]+)|') do
          if not own[name] and not builtin[name] then
            broken[#broken + 1] = string.format('%s:%d |%s|', DOC, i, name)
          end
        end
      end
      test.assert_eq(#broken, 0, 'broken help links:\n' .. table.concat(broken, '\n'))
    end,
  },
})
