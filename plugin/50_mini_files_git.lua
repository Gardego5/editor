local ns = vim.api.nvim_create_namespace("mini_files_git")
local MiniFiles = require("mini.files")

---@type table<string, {
---  time: number,
---  status: table<string, string>,
---  deleted_status: table<string, string>,
---}>
local git_status_cache = {}
local cache_timeout = 2000
---@type table<number, number>
local virtual_line_counts = {}

---@param buf_id number
---@return string|nil
local function get_buffer_path(buf_id)
  local state = MiniFiles.get_explorer_state()

  if state then
    for _, window in ipairs(state.windows) do
      if window.win_id and vim.api.nvim_win_is_valid(window.win_id) and vim.api.nvim_win_get_buf(window.win_id) == buf_id then
        return window.path
      end
    end
  end

  local ok, entry = pcall(MiniFiles.get_fs_entry, buf_id, 1)
  if not ok then
    return nil
  end

  return entry and vim.fs.dirname(entry.path) or nil
end

local function get_max_window_height()
  local has_tabline = vim.o.showtabline == 2 or (vim.o.showtabline == 1 and #vim.api.nvim_list_tabpages() > 1)
  local has_statusline = vim.o.laststatus > 0

  return vim.o.lines - vim.o.cmdheight - (has_tabline and 1 or 0) - (has_statusline and 1 or 0) - 2
end

---@param win_id number
---@param buf_id number
local function update_window_height(win_id, buf_id)
  if not vim.api.nvim_win_is_valid(win_id) or vim.api.nvim_win_get_buf(win_id) ~= buf_id then
    return
  end

  local virtual_line_count = virtual_line_counts[buf_id] or 0
  local height = math.min(vim.api.nvim_buf_line_count(buf_id) + virtual_line_count, get_max_window_height())
  local config = vim.api.nvim_win_get_config(win_id)

  if config.height ~= height then
    config.height = height
    vim.api.nvim_win_set_config(win_id, config)
  end
end

---@param buf_id number
local function update_buffer_window_height(buf_id)
  local state = MiniFiles.get_explorer_state()

  if not state then
    return
  end

  for _, window in ipairs(state.windows) do
    if window.win_id and vim.api.nvim_win_is_valid(window.win_id) and vim.api.nvim_win_get_buf(window.win_id) == buf_id then
      update_window_height(window.win_id, buf_id)
    end
  end
end

---@param status string
local function map_status_hl(status)
  local status_map = {
    [" M"] =  "MiniDiffSignChange",
    ["M "] =  "MiniDiffSignChange",
    ["MM"] =  "MiniDiffSignChange",

    ["A "] =  "MiniDiffSignAdd",
    ["AM"] =  "MiniDiffSignAdd",
    ["AA"] =  "MiniDiffSignAdd",

    ["D "] =  "MiniDiffSignDelete",
    [" D"] =  "MiniDiffSignDelete",
    ["DD"] =  "MiniDiffSignDelete",
    ["AD"] =  "MiniDiffSignDelete",

    ["R "] =  "MiniDiffSignChange",

    ["??"] =  "MiniDiffSignAdd",
  }

  return status_map[status]
end

---@param output string
---@return table<string, string> status
---@return table<string, string> deleted_status
local function parse_git_status(output)
  local result = {}
  local deleted_status = {}

  for line in output:gmatch("[^\r\n]+") do
    local status, path = line:match("^(..) (.*)$")

    if status and path then
      result[path] = status

      if status:find("D", 1, true) then
        deleted_status[path] = status
      end

      -- Also mark all parent directories.
      local parts = vim.split(path, "/", { plain = true })

      for i = 1, #parts - 1 do
        local dir = table.concat(parts, "/", 1, i)

        if not result[dir] then
          result[dir] = status
        end
      end
    end
  end

  return result, deleted_status
end

---@param buf_id number
---@param git_status table<string, string>
---@param deleted_status table<string, string>
local function update_buffer(buf_id, git_status, deleted_status)
  if not vim.api.nvim_buf_is_valid(buf_id) then
    return
  end

  vim.api.nvim_buf_clear_namespace(buf_id, ns, 0, -1)
  virtual_line_counts[buf_id] = 0

  local buffer_path = get_buffer_path(buf_id)
  local git_root = buffer_path and vim.fs.root(buffer_path, ".git")
  if not git_root then
    update_buffer_window_height(buf_id)
    return
  end

  local visible_paths = {}

  for line = 1, vim.api.nvim_buf_line_count(buf_id) do
    local entry = MiniFiles.get_fs_entry(buf_id, line)

    if entry then
      local relative_path = vim.fs.relpath(git_root, entry.path)

      if relative_path then
        visible_paths[relative_path] = true
        local status = git_status[relative_path]

        local raw_line = vim.api.nvim_buf_get_lines(buf_id, line - 1, line, false)[1]
        local _, name_start = raw_line:match("^/%d+/().-()/")

        if name_start then
          local marker = status and status .. " " or "   "
          local marker_hl = status and map_status_hl(status) or nil

          vim.api.nvim_buf_set_extmark(buf_id, ns, line - 1, name_start - 1, {
            virt_text = { { marker, marker_hl } },
            virt_text_pos = "inline",
            right_gravity = false,
            priority = 10,
          })
        end
      end
    end
  end

  local removed_paths = {}
  for path, status in pairs(deleted_status) do
    local absolute_path = vim.fs.joinpath(git_root, path)
    local is_current_directory = vim.fs.dirname(absolute_path) == buffer_path

    if not visible_paths[path] and is_current_directory then
      table.insert(removed_paths, { path = path, status = status })
    end
  end

  table.sort(removed_paths, function(a, b)
    return a.path < b.path
  end)

  if #removed_paths == 0 then
    update_buffer_window_height(buf_id)
    return
  end

  local virtual_lines = {}
  for _, removed in ipairs(removed_paths) do
    local path = vim.fs.joinpath(git_root, removed.path)
    local prefix, prefix_hl = MiniFiles.config.content.prefix({
      fs_type = "file",
      name = vim.fs.basename(removed.path),
      path = path,
    })

    table.insert(virtual_lines, {
      { prefix, prefix_hl },
      { removed.status .. " ", map_status_hl(removed.status) },
      { removed.path, "MiniFilesNormal" },
    })
  end

  vim.api.nvim_buf_set_extmark(buf_id, ns, vim.api.nvim_buf_line_count(buf_id) - 1, 0, {
    virt_lines = virtual_lines,
    virt_lines_above = false,
    priority = 10,
  })

  virtual_line_counts[buf_id] = #virtual_lines
  update_buffer_window_height(buf_id)
end

---@param buf_id number
local function refresh_git_status(buf_id)
  local buffer_path = get_buffer_path(buf_id)
  local git_root = buffer_path and vim.fs.root(buffer_path, ".git")

  if not git_root then
    return
  end

  local cached = git_status_cache[git_root]

  if cached and (vim.uv.now() - cached.time) < cache_timeout then
    update_buffer(buf_id, cached.status, cached.deleted_status)
    return
  end

  vim.system({
    "git",
    "-C",
    git_root,
    "status",
    "--porcelain",
    "--untracked-files=all",
  }, {
    text = true,
  }, function(result)
    if result.code ~= 0 then
      return
    end

    local status, deleted_status = parse_git_status(result.stdout)

    git_status_cache[git_root] = {
      time = vim.uv.now(),
      status = status,
      deleted_status = deleted_status,
    }

    vim.schedule(function()
      update_buffer(buf_id, status, deleted_status)
    end)
  end)
end

vim.api.nvim_create_autocmd("User", {
  pattern = "MiniFilesBufferUpdate",
  callback = function(args)
    ---@type number
    local buf_id = args.data.buf_id
    refresh_git_status(buf_id)
  end,
})

vim.api.nvim_create_autocmd("User", {
  pattern = "MiniFilesBufferCreate",
  callback = function(args)
    ---@type number
    local buf_id = args.data.buf_id
    vim.keymap.set("n", "gR", function()
      git_status_cache = {}

      MiniFiles.refresh({
        content = {
          highlight = MiniFiles.config.content.highlight,
        },
      })
    end, {
      buffer = buf_id,
      desc = "Refresh git status",
    })
  end,
})

vim.api.nvim_create_autocmd("User", {
  pattern = "MiniFilesWindowUpdate",
  callback = function(args)
    local buf_id = args.data.buf_id

    if virtual_line_counts[buf_id] ~= nil then
      update_window_height(args.data.win_id, buf_id)
    end
  end,
})
