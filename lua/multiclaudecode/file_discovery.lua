-- File discovery and tracking system for enhanced Claude Code prompts
local M = {}

-- Internal state
local file_cache = {}
local workspace_root = nil
local last_scan_time = 0
local scan_interval = 5000 -- 5 seconds

-- Configuration
M.config = {
  max_files = 1000,
  exclude_patterns = {
    "%.git/",
    "node_modules/",
    "%.DS_Store",
    "%.pyc$",
    "__pycache__/",
    "%.class$",
    "target/",
    "dist/",
    "build/",
    "%.min%.js$",
    "%.min%.css$",
    "%.lock$",
    "%.log$",
    "%.tmp$",
    "%.temp$",
  },
  include_patterns = {
    "%.lua$",
    "%.py$",
    "%.js$",
    "%.ts$",
    "%.jsx$",
    "%.tsx$",
    "%.go$",
    "%.rs$",
    "%.c$",
    "%.cpp$",
    "%.h$",
    "%.hpp$",
    "%.java$",
    "%.kt$",
    "%.swift$",
    "%.php$",
    "%.rb$",
    "%.sh$",
    "%.zsh$",
    "%.fish$",
    "%.md$",
    "%.rst$",
    "%.txt$",
    "%.json$",
    "%.yaml$",
    "%.yml$",
    "%.xml$",
    "%.html$",
    "%.css$",
    "%.scss$",
    "%.sass$",
    "%.less$",
    "%.vim$",
    "%.toml$",
    "%.cfg$",
    "%.ini$",
    "%.conf$",
    "Makefile$",
    "Dockerfile$",
    "%.gitignore$",
    "%.gitmodules$",
    "README",
    "CHANGELOG",
    "LICENSE",
  },
  max_depth = 10,
  recent_files_count = 50,
}

-- Find workspace root
local function find_workspace_root()
  local cwd = vim.fn.getcwd()
  local root_markers = {
    ".git",
    ".hg",
    ".svn",
    "package.json",
    "Cargo.toml",
    "go.mod",
    "setup.py",
    "pyproject.toml",
    "pom.xml",
    "build.gradle",
    "Makefile",
    "CMakeLists.txt",
  }
  
  local current_dir = cwd
  local max_depth = 20
  local depth = 0
  
  while current_dir ~= "/" and depth < max_depth do
    for _, marker in ipairs(root_markers) do
      local marker_path = current_dir .. "/" .. marker
      if vim.fn.filereadable(marker_path) == 1 or vim.fn.isdirectory(marker_path) == 1 then
        return current_dir
      end
    end
    
    current_dir = vim.fn.fnamemodify(current_dir, ":h")
    depth = depth + 1
  end
  
  return cwd
end

-- Check if file should be included
local function should_include_file(filepath)
  local filename = vim.fn.fnamemodify(filepath, ":t")
  local relative_path = vim.fn.fnamemodify(filepath, ":.")
  
  -- Check exclude patterns
  for _, pattern in ipairs(M.config.exclude_patterns) do
    if relative_path:match(pattern) or filename:match(pattern) then
      return false
    end
  end
  
  -- Check include patterns
  for _, pattern in ipairs(M.config.include_patterns) do
    if filename:match(pattern) or relative_path:match(pattern) then
      return true
    end
  end
  
  return false
end

-- Get file info
local function get_file_info(filepath)
  local stat = vim.loop.fs_stat(filepath)
  if not stat then
    return nil
  end
  
  local relative_path = vim.fn.fnamemodify(filepath, ":.")
  local filename = vim.fn.fnamemodify(filepath, ":t")
  local extension = vim.fn.fnamemodify(filepath, ":e")
  local directory = vim.fn.fnamemodify(filepath, ":h")
  
  return {
    filepath = filepath,
    relative_path = relative_path,
    filename = filename,
    extension = extension,
    directory = directory,
    size = stat.size,
    mtime = stat.mtime.sec,
    is_git_tracked = M.is_git_tracked(filepath),
    display_name = relative_path,
    search_text = filename .. " " .. relative_path .. " " .. extension,
  }
end

-- Check if file is git tracked
function M.is_git_tracked(filepath)
  local git_cmd = string.format("git ls-files --error-unmatch %s", vim.fn.shellescape(filepath))
  local result = vim.fn.system(git_cmd)
  return vim.v.shell_error == 0
end

-- Scan directory recursively
local function scan_directory(dir, current_depth)
  if current_depth > M.config.max_depth then
    return {}
  end
  
  local files = {}
  local handle = vim.loop.fs_scandir(dir)
  
  if not handle then
    return files
  end
  
  while true do
    local name, type = vim.loop.fs_scandir_next(handle)
    if not name then
      break
    end
    
    local full_path = dir .. "/" .. name
    
    if type == "file" then
      if should_include_file(full_path) then
        local info = get_file_info(full_path)
        if info then
          table.insert(files, info)
        end
      end
    elseif type == "directory" and not name:match("^%.") then
      -- Skip hidden directories and scan subdirectories
      if not name:match("^%.git$") and not name:match("node_modules") then
        local subfiles = scan_directory(full_path, current_depth + 1)
        vim.list_extend(files, subfiles)
      end
    end
    
    -- Limit total files to prevent memory issues
    if #files >= M.config.max_files then
      break
    end
  end
  
  return files
end

-- Refresh file cache
function M.refresh_cache(force)
  local current_time = vim.loop.now()
  
  if not force and (current_time - last_scan_time) < scan_interval then
    return file_cache
  end
  
  workspace_root = find_workspace_root()
  local files = scan_directory(workspace_root, 0)
  
  -- Sort files by modification time (most recent first)
  table.sort(files, function(a, b)
    return a.mtime > b.mtime
  end)
  
  file_cache = files
  last_scan_time = current_time
  
  return file_cache
end

-- Get all files in workspace
function M.get_all_files()
  return M.refresh_cache(false)
end

-- Get recent files
function M.get_recent_files(count)
  local files = M.get_all_files()
  local recent = {}
  
  count = count or M.config.recent_files_count
  
  for i = 1, math.min(count, #files) do
    table.insert(recent, files[i])
  end
  
  return recent
end

-- Search files by name or path
function M.search_files(query)
  if not query or query == "" then
    return M.get_recent_files()
  end
  
  local files = M.get_all_files()
  local results = {}
  local query_lower = query:lower()
  
  for _, file in ipairs(files) do
    local search_text = file.search_text:lower()
    if search_text:find(query_lower, 1, true) then
      table.insert(results, file)
    end
  end
  
  -- Sort results by relevance
  table.sort(results, function(a, b)
    local a_score = M.calculate_relevance_score(a, query_lower)
    local b_score = M.calculate_relevance_score(b, query_lower)
    return a_score > b_score
  end)
  
  return results
end

-- Calculate relevance score for search results
function M.calculate_relevance_score(file, query)
  local score = 0
  local filename_lower = file.filename:lower()
  local path_lower = file.relative_path:lower()
  
  -- Exact filename match gets highest score
  if filename_lower == query then
    score = score + 100
  elseif filename_lower:find("^" .. query) then
    score = score + 80
  elseif filename_lower:find(query) then
    score = score + 60
  end
  
  -- Path matches get lower score
  if path_lower:find(query) then
    score = score + 20
  end
  
  -- Boost score for recently modified files
  local age_days = (os.time() - file.mtime) / 86400
  if age_days < 1 then
    score = score + 10
  elseif age_days < 7 then
    score = score + 5
  end
  
  -- Boost score for git-tracked files
  if file.is_git_tracked then
    score = score + 5
  end
  
  return score
end

-- Get files by extension
function M.get_files_by_extension(extension)
  local files = M.get_all_files()
  local results = {}
  
  for _, file in ipairs(files) do
    if file.extension == extension then
      table.insert(results, file)
    end
  end
  
  return results
end

-- Get files in directory
function M.get_files_in_directory(dir)
  local files = M.get_all_files()
  local results = {}
  local normalized_dir = vim.fn.fnamemodify(dir, ":.")
  
  for _, file in ipairs(files) do
    if file.directory == normalized_dir or file.directory:find("^" .. normalized_dir .. "/") then
      table.insert(results, file)
    end
  end
  
  return results
end

-- Get current buffer info
function M.get_current_buffer_info()
  local bufnr = vim.api.nvim_get_current_buf()
  local filepath = vim.api.nvim_buf_get_name(bufnr)
  
  if filepath == "" then
    return nil
  end
  
  return get_file_info(filepath)
end

-- Get recently opened files from Neovim
function M.get_vim_recent_files()
  local recent_files = {}
  
  -- Get files from oldfiles
  local oldfiles = vim.v.oldfiles or {}
  for _, file in ipairs(oldfiles) do
    if vim.fn.filereadable(file) == 1 then
      local info = get_file_info(file)
      if info then
        table.insert(recent_files, info)
      end
      if #recent_files >= 20 then
        break
      end
    end
  end
  
  -- Get files from current session buffers
  local buffers = vim.api.nvim_list_bufs()
  for _, bufnr in ipairs(buffers) do
    if vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_get_option(bufnr, "buflisted") then
      local filepath = vim.api.nvim_buf_get_name(bufnr)
      if filepath ~= "" and vim.fn.filereadable(filepath) == 1 then
        local info = get_file_info(filepath)
        if info then
          -- Add to front of list if not already present
          local already_exists = false
          for _, existing in ipairs(recent_files) do
            if existing.filepath == info.filepath then
              already_exists = true
              break
            end
          end
          if not already_exists then
            table.insert(recent_files, 1, info)
          end
        end
      end
    end
  end
  
  return recent_files
end

-- Get workspace statistics
function M.get_workspace_stats()
  local files = M.get_all_files()
  local stats = {
    total_files = #files,
    root = workspace_root,
    by_extension = {},
    recent_count = 0,
    git_tracked_count = 0,
  }
  
  local now = os.time()
  
  for _, file in ipairs(files) do
    -- Count by extension
    local ext = file.extension
    if ext == "" then
      ext = "no_extension"
    end
    stats.by_extension[ext] = (stats.by_extension[ext] or 0) + 1
    
    -- Count recent files (modified in last 7 days)
    if (now - file.mtime) < (7 * 24 * 60 * 60) then
      stats.recent_count = stats.recent_count + 1
    end
    
    -- Count git-tracked files
    if file.is_git_tracked then
      stats.git_tracked_count = stats.git_tracked_count + 1
    end
  end
  
  return stats
end

-- Setup function
function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})
  
  -- Initial cache refresh
  M.refresh_cache(true)
  
  -- Set up autocmds for cache invalidation
  local group = vim.api.nvim_create_augroup("MultiClaudeCodeFileDiscovery", { clear = true })
  
  -- Refresh cache when files are saved
  vim.api.nvim_create_autocmd({ "BufWritePost" }, {
    group = group,
    callback = function()
      -- Refresh cache in background
      vim.schedule(function()
        M.refresh_cache(true)
      end)
    end,
  })
  
  -- Refresh cache when entering new directories
  vim.api.nvim_create_autocmd({ "DirChanged" }, {
    group = group,
    callback = function()
      workspace_root = nil
      vim.schedule(function()
        M.refresh_cache(true)
      end)
    end,
  })
end

return M