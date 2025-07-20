local M = {}

M.sessions = {}
M.repository_spawned = {}  -- Track repositories where we've spawned sessions
M.dashboard = {
  active = false,
  tab_id = nil,
  windows = {},
  update_timer = nil,
}
M.config = {
  notify_on_complete = true,
  claude_code_path = "claude",
  hooks_dir = vim.fn.stdpath("data") .. "/multiclaudecode/hooks",
  notification_port = 9999,
  default_args = {},
  skip_permissions = true,  -- Add --dangerously-skip-permissions by default
  model = "sonnet",  -- Default model ("opus" or "sonnet")
  terminal = {
    split_direction = "right",  -- "float", "botright", "topleft", "vertical", etc.
    split_size = 0.4,  -- Percentage of screen (0.4 = 40%)
    start_insert = true,  -- Automatically enter insert mode
    close_on_exit = false,  -- Close terminal window when process exits
    show_only_first_time = false,  -- Only show floating terminal for first spawn in new repository
    float_opts = {
      relative = "editor",
      width = 0.8,  -- 80% of editor width
      height = 0.8,  -- 80% of editor height
      border = "rounded",
    },
  },
  keymaps = {
    spawn = "<leader>cs",          -- Spawn new session with enhanced prompt
    spawn_with_selection = "<leader>ce", -- Spawn with visual selection/current line
    spawn_no_prompt = "<leader>cn", -- Spawn new session without prompt
    spawn_safe = "<leader>cp",     -- Spawn new session without --dangerously-skip-permissions
    toggle = "<leader>ct",         -- Toggle session visibility
    kill = "<leader>ck",           -- Kill session
    list = "<leader>cl",           -- List sessions (telescope)
    attach = "<leader>ca",         -- Attach to last session
    enhanced_spawn = "<leader>cS", -- Enhanced spawn with file suggestions
    custom_input_spawn = "<leader>cc", -- Spawn with custom input (non-Telescope)
    dashboard = "<leader>cd",      -- Open/show dashboard with all running sessions in grid
    dashboard_close = "<leader>cdc", -- Close dashboard
  },
  enhanced_prompt = {
    enable_file_suggestions = true,
    enable_prompt_history = true,
    max_history_entries = 100,
    suggestion_trigger = "@",
    file_trigger = "file:",
    auto_trigger_chars = { "@", ":", "/" },
    show_recent_files = true,
    show_git_files = true,
    max_suggestions = 20,
    file_discovery = {
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
      max_depth = 10,
      recent_files_count = 50,
    },
  },
  lualine = {
    enabled = true,
    refresh_rate = 5000,  -- Refresh every 5 seconds
    component_type = "detailed",  -- "simple" or "detailed"
    colors = {
      running = "#50fa7b",  -- Green for running sessions
      idle = "#6272a4",     -- Gray for idle/completed sessions
    },
  },
  dashboard = {
    auto_update = true,    -- Auto-update when sessions change
    update_interval = 2000, -- Update interval in milliseconds
    max_rows = 4,          -- Maximum rows in grid
    min_columns = 2,       -- Minimum columns in grid
    max_columns = 4,       -- Maximum columns in grid
  },
}

local function ensure_hooks_dir()
  vim.fn.mkdir(M.config.hooks_dir, "p")
end

local function create_float_window(buf)
  local opts = M.config.terminal.float_opts
  
  -- Calculate dimensions
  local width = math.floor(vim.o.columns * (opts.width or 0.8))
  local height = math.floor(vim.o.lines * (opts.height or 0.8))
  
  -- Calculate position to center the window
  local row = math.floor((vim.o.lines - height) / 2)
  local col = math.floor((vim.o.columns - width) / 2)
  
  local win_opts = {
    relative = opts.relative or "editor",
    width = width,
    height = height,
    row = row,
    col = col,
    style = "minimal",
    border = opts.border or "rounded",
  }
  
  local win = vim.api.nvim_open_win(buf, true, win_opts)
  
  -- Set window options
  vim.api.nvim_win_set_option(win, "winhl", "Normal:Normal,FloatBorder:FloatBorder")
  
  return win
end

local function create_session_hook(session_id, event_type)
  local hook_content = string.format([[
#!/bin/bash
# Hook for session %s - %s event
if [ "$1" = "Notification" ]; then
  # For Notification events, Claude passes JSON as second argument
  json_data="$2"
  # Add session_id and hook_event_name to the JSON
  modified_json=$(echo "$json_data" | jq --arg sid "%s" --arg event "$1" '. + {session_id: $sid, hook_event_name: $event}')
  curl -X POST http://localhost:%d/notify -H "Content-Type: application/json" -d "$modified_json" 2>/dev/null || true
else
  # For other events like PostToolUse
  curl -X POST http://localhost:%d/notify -H "Content-Type: application/json" -d '{"session_id":"%s","hook_event_name":"'$1'","event":"complete"}' 2>/dev/null || true
fi
]], session_id, event_type, session_id, M.notification_server_port or 9999, M.notification_server_port or 9999, session_id)
  
  local hook_path = M.config.hooks_dir .. "/session_" .. session_id .. "_" .. event_type .. "_hook.sh"
  local file = io.open(hook_path, "w")
  if file then
    file:write(hook_content)
    file:close()
    vim.fn.system("chmod +x " .. hook_path)
    return hook_path
  end
  return nil
end

local function update_claude_settings(session_id, hook_paths)
  local settings_path = vim.fn.expand("~/.claude/settings.json")
  
  -- Ensure directory exists
  vim.fn.mkdir(vim.fn.expand("~/.claude"), "p")
  
  -- Read existing settings
  local file = io.open(settings_path, "r")
  local settings = {}
  if file then
    local content = file:read("*all")
    file:close()
    local ok, parsed = pcall(vim.json.decode, content)
    if ok then
      settings = parsed
    end
  end
  
  -- Initialize hooks structure if needed
  if not settings.hooks then
    settings.hooks = {}
  end
  
  -- Add hooks for each event type
  for event_type, hook_path in pairs(hook_paths) do
    if not settings.hooks[event_type] then
      settings.hooks[event_type] = {}
    end
    
    -- Add hook for this session
    local hook_entry = {
      matcher = "*",
      hooks = {
        {
          type = "command",
          command = hook_path
        }
      }
    }
    
    -- Tag the hook with session ID for later cleanup
    hook_entry.hooks[1].metadata = { session_id = session_id }
    
    table.insert(settings.hooks[event_type], hook_entry)
  end
  
  -- Write back settings
  local out_file = io.open(settings_path, "w")
  if out_file then
    out_file:write(vim.json.encode(settings))
    out_file:close()
    return true
  end
  return false
end

local function remove_session_hook_from_settings(session_id)
  local settings_path = vim.fn.expand("~/.claude/settings.json")
  
  -- Read existing settings
  local file = io.open(settings_path, "r")
  if not file then
    return
  end
  
  local content = file:read("*all")
  file:close()
  
  local ok, settings = pcall(vim.json.decode, content)
  if not ok or not settings.hooks then
    return
  end
  
  -- Remove hooks for this session from all event types
  for event_type, hooks in pairs(settings.hooks) do
    if type(hooks) == "table" and #hooks > 0 then
      local new_hooks = {}
      for _, hook_entry in ipairs(hooks) do
        local keep = true
        if hook_entry.hooks then
          for _, hook in ipairs(hook_entry.hooks) do
            if hook.metadata and hook.metadata.session_id == session_id then
              keep = false
              break
            end
          end
        end
        if keep then
          table.insert(new_hooks, hook_entry)
        end
      end
      settings.hooks[event_type] = new_hooks
    end
  end
  
  -- Write back settings
  local out_file = io.open(settings_path, "w")
  if out_file then
    out_file:write(vim.json.encode(settings))
    out_file:close()
  end
end

local function get_repository_root()
  local cwd = vim.fn.getcwd()
  local git_root = vim.fn.systemlist("git -C " .. vim.fn.shellescape(cwd) .. " rev-parse --show-toplevel 2>/dev/null")[1]
  return git_root and git_root or cwd
end

local function close_existing_session_windows()
  -- Find all currently visible session windows and close them
  -- BUT exclude dashboard windows when dashboard is active
  for session_id, session in pairs(M.sessions) do
    if session.buf and vim.api.nvim_buf_is_valid(session.buf) then
      for _, win in ipairs(vim.api.nvim_list_wins()) do
        if vim.api.nvim_win_get_buf(win) == session.buf then
          -- If dashboard is active, don't close windows that are part of the dashboard
          if M.dashboard.active and M.dashboard.windows[session_id] == win then
            -- Skip closing this window as it's part of the dashboard
          else
            vim.api.nvim_win_close(win, false)
          end
        end
      end
    end
  end
end

local function spawn_claude_session(args)
  local session_id = tostring(os.time()) .. "_" .. tostring(math.random(10000))
  
  -- Close any existing session windows before spawning new one (but not dashboard)
  if not M.dashboard.active then
    close_existing_session_windows()
  end
  
  ensure_hooks_dir()
  
  -- Create hooks for both PostToolUse and Notification events
  local hook_paths = {}
  local post_tool_hook = create_session_hook(session_id, "PostToolUse")
  local notification_hook = create_session_hook(session_id, "Notification")
  
  if not post_tool_hook or not notification_hook then
    vim.notify("Failed to create session hooks", vim.log.levels.ERROR)
    return nil
  end
  
  hook_paths.PostToolUse = post_tool_hook
  hook_paths.Notification = notification_hook
  
  -- Update Claude settings with the hooks
  if not update_claude_settings(session_id, hook_paths) then
    vim.notify("Failed to update Claude settings", vim.log.levels.ERROR)
    return nil
  end
  
  local cmd_args = vim.tbl_deep_extend("force", M.config.default_args, args or {})
  local cmd = {M.config.claude_code_path}
  
  -- Extract message before processing other args
  local message = nil
  if cmd_args.message then
    message = cmd_args.message
    cmd_args.message = nil  -- Remove from args so it's not treated as a flag
  end
  
  -- Add --dangerously-skip-permissions if configured
  if M.config.skip_permissions then
    table.insert(cmd, "--dangerously-skip-permissions")
  end
  
  -- Add --model if configured
  if M.config.model then
    table.insert(cmd, "--model")
    table.insert(cmd, M.config.model)
  end
  
  -- Add other arguments
  for k, v in pairs(cmd_args) do
    if type(k) == "number" then
      table.insert(cmd, v)
    else
      table.insert(cmd, "--" .. k)
      if v ~= true then
        table.insert(cmd, tostring(v))
      end
    end
  end
  
  -- Add message as last argument if provided
  if message then
    table.insert(cmd, message)
  end
  
  -- Create a new buffer for the terminal
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, "ClaudeCode: " .. session_id)
  
  -- Check if we should show terminal window
  local repo_root = get_repository_root()
  local should_show_window = true
  
  if M.config.terminal.show_only_first_time then
    if M.repository_spawned[repo_root] then
      should_show_window = false
    else
      M.repository_spawned[repo_root] = true
    end
  end
  
  -- Open buffer in a new window (only if should_show_window is true and dashboard is not active)
  local win
  if should_show_window and not M.dashboard.active then
    local split_cmd = M.config.terminal.split_direction
    
    if split_cmd == "float" then
      win = create_float_window(buf)
    else
      -- Regular split window
      local split_size = M.config.terminal.split_size
      
      if split_cmd == "vertical" or split_cmd == "right" then
        local win_width = math.floor(vim.o.columns * split_size)
        if split_cmd == "right" then
          vim.cmd(string.format("rightbelow vertical %dsplit", win_width))
        else
          vim.cmd(string.format("vertical %dsplit", win_width))
        end
      else
        local win_height = math.floor(vim.o.lines * split_size)
        vim.cmd(string.format("%s %dsplit", split_cmd, win_height))
      end
      
      win = vim.api.nvim_get_current_win()
      vim.api.nvim_win_set_buf(win, buf)
    end
  end
  
  -- Start terminal with claude code
  -- If no window is set (dashboard is active), we need to temporarily set the buffer
  local needs_temp_window = not win and M.dashboard.active
  if needs_temp_window then
    -- Save current window
    local current_win = vim.api.nvim_get_current_win()
    -- Create a temporary split
    vim.cmd("split")
    win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, buf)
  end
  
  local term_id = vim.fn.termopen(cmd, {
    on_exit = function(_, exit_code)
      if M.sessions[session_id] then
        M.sessions[session_id].exit_code = exit_code
        M.sessions[session_id].status = "completed"
        if M.config.notify_on_complete then
          vim.notify(string.format("Claude Code session %s completed with exit code %d", 
            session_id, exit_code), vim.log.levels.INFO)
        end
        
        -- Clean up hook from settings
        remove_session_hook_from_settings(session_id)
        
        -- Remove hook script files
        local hook_files = vim.fn.glob(M.config.hooks_dir .. "/session_" .. session_id .. "_*.sh", true, true)
        for _, hook_file in ipairs(hook_files) do
          vim.fn.delete(hook_file)
        end
        
        -- Update dashboard if active
        if M.dashboard.active then
          vim.schedule(function()
            M.update_dashboard()
          end)
        end
      end
    end,
  })
  
  -- Enter insert mode if configured (only if window is shown)
  if M.config.terminal.start_insert and win then
    vim.cmd("startinsert")
  end
  
  -- Set buffer options
  vim.api.nvim_buf_set_option(buf, "filetype", "claudecode")
  vim.api.nvim_buf_set_option(buf, "bufhidden", "hide")
  
  -- Set up keymaps to hide the window
  local function hide_window()
    if win and vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, false)
    end
  end
  
  -- Terminal mode mappings
  -- vim.api.nvim_buf_set_keymap(buf, 't', '<C-Esc>', '<C-\\><C-n>:lua vim.api.nvim_win_close(0, false)<CR>', {
  --   noremap = true,
  --   silent = true,
  --   desc = "Hide Claude Code window"
  -- })
  --
  -- -- Normal mode mappings
  -- vim.api.nvim_buf_set_keymap(buf, 'n', '<C-Esc>', ':lua vim.api.nvim_win_close(0, false)<CR>', {
  --   noremap = true,
  --   silent = true,
  --   desc = "Hide Claude Code window"
  -- })
  
  vim.api.nvim_buf_set_keymap(buf, 'n', '<C-q>', ':lua vim.api.nvim_win_close(0, false)<CR>', {
    noremap = true,
    silent = true,
    desc = "Hide Claude Code window"
  })
  
  -- Set up autocmd to handle window closing
  if M.config.terminal.close_on_exit then
    vim.api.nvim_create_autocmd("TermClose", {
      buffer = buf,
      callback = function()
        vim.schedule(function()
          if vim.api.nvim_buf_is_valid(buf) then
            vim.api.nvim_buf_delete(buf, { force = true })
          end
        end)
      end,
    })
  end
  
  -- Close temporary window if created
  if needs_temp_window and win then
    vim.api.nvim_win_close(win, true)
    win = nil  -- Reset win since we closed it
  end
  
  -- Store session information
  M.sessions[session_id] = {
    id = session_id,
    term_id = term_id,
    buf = buf,
    win = win,
    args = cmd_args,
    status = "running",
    started_at = os.time(),
    repo_root = repo_root,
    window_shown = should_show_window,
  }
  
  -- Notify user about session spawn
  if not should_show_window then
    vim.notify(string.format("Claude Code session %s spawned in background (use :ClaudeCodeList to access)", session_id), vim.log.levels.INFO)
  end
  
  -- Update dashboard if active
  if M.dashboard.active then
    vim.schedule(function()
      M.update_dashboard()
    end)
  end
  
  return session_id
end

function M.spawn(args)
  vim.ui.input({
    prompt = "Claude Code prompt: ",
    default = "",
  }, function(input)
    if not input or input == "" then
      return
    end
    
    -- Create new args table with message
    local spawn_args = vim.tbl_deep_extend("force", args or {}, { message = input })
    
    local session_id = spawn_claude_session(spawn_args)
    if session_id then
      vim.notify("Started Claude Code session: " .. session_id, vim.log.levels.INFO)
    end
  end)
end

-- Spawn without prompt
function M.spawn_no_prompt(args)
  local session_id = spawn_claude_session(args or {})
  if session_id then
    vim.notify("Started Claude Code session: " .. session_id, vim.log.levels.INFO)
  end
  return session_id
end

-- Enhanced spawn with file suggestions and prompt history
function M.enhanced_spawn(args)
  -- Check if enhanced prompt is available
  local has_enhanced_prompt, enhanced_prompt = pcall(require, "multiclaudecode.enhanced_prompt")
  
  if has_enhanced_prompt then
    enhanced_prompt.enhanced_spawn(args, M)
  else
    -- Fallback to regular spawn
    M.spawn(args)
  end
end

-- Spawn with custom input (non-Telescope)
function M.spawn_with_custom_input(args)
  local has_custom_input, custom_input = pcall(require, "multiclaudecode.custom_input")
  
  if has_custom_input then
    custom_input.spawn_with_custom_input(M, args)
  else
    -- Show error and fallback to regular spawn
    vim.notify("Error loading custom_input module: " .. tostring(custom_input), vim.log.levels.ERROR)
    M.spawn(args)
  end
end

-- Spawn without --dangerously-skip-permissions (safe spawn)
function M.spawn_safe(args)
  -- Temporarily disable skip_permissions for this spawn
  local original_skip = M.config.skip_permissions
  M.config.skip_permissions = false
  
  vim.ui.input({
    prompt = "Claude Code prompt (safe mode): ",
    default = "",
  }, function(input)
    if not input or input == "" then
      M.config.skip_permissions = original_skip
      return
    end
    
    -- Create new args table with message
    local spawn_args = vim.tbl_deep_extend("force", args or {}, { message = input })
    
    local session_id = spawn_claude_session(spawn_args)
    if session_id then
      vim.notify("Started Claude Code session (safe mode): " .. session_id, vim.log.levels.INFO)
    end
    
    -- Restore original setting
    M.config.skip_permissions = original_skip
  end)
end

-- Spawn with initial message
function M.spawn_with_message(message, args)
  -- Create new args table with message
  local spawn_args = vim.tbl_deep_extend("force", args or {}, { message = message })
  
  local session_id = spawn_claude_session(spawn_args)
  if session_id then
    vim.notify("Started Claude Code session: " .. session_id, vim.log.levels.INFO)
  end
  return session_id
end

-- Spawn with visual selection
function M.spawn_with_selection()
  -- Get visual selection
  local start_pos = vim.fn.getpos("'<")
  local end_pos = vim.fn.getpos("'>")
  local lines = vim.api.nvim_buf_get_lines(0, start_pos[2] - 1, end_pos[2], false)
  
  if #lines == 0 then
    vim.notify("No selection found", vim.log.levels.WARN)
    return
  end
  
  -- Handle partial selection on first and last lines
  if #lines == 1 then
    lines[1] = lines[1]:sub(start_pos[3], end_pos[3])
  else
    lines[1] = lines[1]:sub(start_pos[3])
    lines[#lines] = lines[#lines]:sub(1, end_pos[3])
  end
  
  local selection = table.concat(lines, "\n")
  
  -- Get file info for context
  local filepath = vim.fn.expand("%:p")
  local filename = vim.fn.expand("%:t")
  local filetype = vim.bo.filetype
  local start_line = start_pos[2]
  local end_line = end_pos[2]
  
  -- Prompt for user input
  vim.ui.input({
    prompt = "Claude Code prompt: ",
    default = "",
  }, function(input)
    if not input then
      return
    end
    
    -- Build message with user prompt and context
    local message = input
    if input ~= "" then
      message = message .. "\n\n"
    end
    
    -- Add file context
    message = message .. string.format("File: %s\nLines: %d-%d\n\n```%s\n%s\n```",
      filepath,
      start_line,
      end_line,
      filetype ~= "" and filetype or "text",
      selection
    )
    
    return M.spawn_with_message(message)
  end)
end

-- Spawn with current line
function M.spawn_with_current_line()
  local line = vim.api.nvim_get_current_line()
  if line == "" then
    vim.notify("Current line is empty", vim.log.levels.WARN)
    return
  end
  
  local filepath = vim.fn.expand("%:p")
  local filename = vim.fn.expand("%:t")
  local filetype = vim.bo.filetype
  local line_num = vim.fn.line(".")
  
  -- Prompt for user input
  vim.ui.input({
    prompt = "Claude Code prompt: ",
    default = "",
  }, function(input)
    if not input then
      return
    end
    
    -- Build message with user prompt and context
    local message = input
    if input ~= "" then
      message = message .. "\n\n"
    end
    
    -- Add file context
    message = message .. string.format("File: %s\nLine: %d\n\n```%s\n%s\n```",
      filepath,
      line_num,
      filetype ~= "" and filetype or "text",
      line
    )
    
    return M.spawn_with_message(message)
  end)
end

-- Spawn with current file path appended to prompt
function M.spawn_with_file_path()
  local filepath = vim.fn.expand("%:p")
  
  if filepath == "" then
    vim.notify("No file currently open", vim.log.levels.WARN)
    return
  end
  
  -- Prompt for user input without showing file path
  vim.ui.input({
    prompt = "Claude Code prompt: ",
    default = "",
  }, function(input)
    if not input then
      return
    end
    
    -- Silently append file path to the prompt
    local message = input
    if input ~= "" then
      message = message .. " " .. filepath
    else
      message = filepath
    end
    
    return M.spawn_with_message(message)
  end)
end

-- Send selection to recent session or toggle session visibility
function M.send_selection_to_recent()
  -- Get visual selection
  local start_pos = vim.fn.getpos("'<")
  local end_pos = vim.fn.getpos("'>")
  local lines = vim.api.nvim_buf_get_lines(0, start_pos[2] - 1, end_pos[2], false)
  
  if #lines == 0 then
    vim.notify("No selection found", vim.log.levels.WARN)
    return
  end
  
  -- Handle partial selection on first and last lines
  if #lines == 1 then
    lines[1] = lines[1]:sub(start_pos[3], end_pos[3])
  else
    lines[1] = lines[1]:sub(start_pos[3])
    lines[#lines] = lines[#lines]:sub(1, end_pos[3])
  end
  
  local selection = table.concat(lines, "\n")
  
  -- Get file info for context
  local filepath = vim.fn.expand("%:p")
  local filename = vim.fn.expand("%:t")
  local filetype = vim.bo.filetype
  local start_line = start_pos[2]
  local end_line = end_pos[2]
  
  -- Build message with file context
  local message = string.format("File: %s\nLines: %d-%d\n\n```%s\n%s\n```",
    filepath,
    start_line,
    end_line,
    filetype ~= "" and filetype or "text",
    selection
  )
  
  -- Get recent session
  local recent = M.get_recent_session()
  
  if not recent then
    -- No sessions exist, spawn a new one with the selection
    return M.spawn_with_message(message)
  end
  
  -- Check if recent session window is visible
  local session_visible = false
  if recent.buf and vim.api.nvim_buf_is_valid(recent.buf) then
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_buf(win) == recent.buf then
        session_visible = true
        break
      end
    end
  end
  
  if not session_visible then
    -- Session exists but not visible, show it and send the selection
    M.attach_to_session(recent.id)
  end
  
  -- Send the selection to the session
  if recent.term_id and recent.status == "running" then
    vim.fn.chansend(recent.term_id, message .. "\n")
    vim.notify("Selection sent to session: " .. recent.id:sub(1, 8), vim.log.levels.INFO)
  else
    vim.notify("Recent session is not running", vim.log.levels.WARN)
  end
end

-- Calculate optimal grid layout for sessions
local function calculate_grid_layout(session_count)
  if session_count == 0 then
    return 0, 0
  end
  
  local max_rows = M.config.dashboard.max_rows
  local min_cols = M.config.dashboard.min_columns
  local max_cols = M.config.dashboard.max_columns or 4
  
  -- For very small counts, use single row
  if session_count <= min_cols then
    return 1, session_count
  end
  
  -- Calculate optimal grid dimensions
  -- Try to keep aspect ratio close to square
  local best_rows, best_cols = 1, session_count
  local best_ratio_diff = math.huge
  
  for rows = 1, math.min(max_rows, session_count) do
    local cols = math.ceil(session_count / rows)
    if cols <= max_cols then
      -- Calculate aspect ratio difference from square
      local ratio_diff = math.abs(cols - rows)
      if ratio_diff < best_ratio_diff then
        best_ratio_diff = ratio_diff
        best_rows = rows
        best_cols = cols
      end
    end
  end
  
  return best_rows, best_cols
end

-- Create dashboard grid layout
local function create_dashboard_grid(running_sessions)
  local session_count = #running_sessions
  if session_count == 0 then
    -- Clear all windows but keep the tab
    for _, win in pairs(M.dashboard.windows) do
      if vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_win_close(win, false)
      end
    end
    M.dashboard.windows = {}
    
    -- Create empty buffer with message
    vim.cmd("enew")
    local buf = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "",
      "  No running Claude Code sessions",
      "",
      "  Use one of the spawn commands to create sessions:",
      "  • <leader>cs - Enhanced spawn with prompt",
      "  • <leader>cn - Spawn without prompt", 
      "  • <leader>cp - Safe spawn (no --dangerously-skip-permissions)",
      ""
    })
    vim.api.nvim_buf_set_option(buf, "modifiable", false)
    vim.api.nvim_buf_set_option(buf, "readonly", true)
    return
  end
  
  local rows, cols = calculate_grid_layout(session_count)
  
  -- Store current tab to restore focus
  local dashboard_tab = M.dashboard.tab_id
  vim.api.nvim_set_current_tabpage(dashboard_tab)
  
  -- Clear existing dashboard windows
  for _, win in pairs(M.dashboard.windows) do
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, false)
    end
  end
  M.dashboard.windows = {}
  
  -- Create main window first
  vim.cmd("enew")
  local main_win = vim.api.nvim_get_current_win()
  
  -- Create grid of splits
  local win_height = math.floor(vim.o.lines / rows)
  local win_width = math.floor(vim.o.columns / cols)
  
  -- Create grid layout using a different approach
  -- First create all vertical splits for the first row
  local current_win = main_win
  local all_windows = {}
  
  -- Create first row
  for col = 1, cols do
    if col > 1 then
      vim.api.nvim_set_current_win(current_win)
      vim.cmd(string.format("rightbelow vertical %dsplit", win_width))
    end
    current_win = vim.api.nvim_get_current_win()
    table.insert(all_windows, current_win)
  end
  
  -- Now create additional rows by splitting each column
  for row = 2, rows do
    for col = 1, cols do
      local parent_win = all_windows[col]
      vim.api.nvim_set_current_win(parent_win)
      vim.cmd(string.format("rightbelow %dsplit", win_height))
      local new_win = vim.api.nvim_get_current_win()
      table.insert(all_windows, new_win)
    end
  end
  
  -- Assign sessions to windows
  local session_index = 1
  for i, win in ipairs(all_windows) do
    if session_index > session_count then
      break
    end
    
    if vim.api.nvim_win_is_valid(win) then
      local session = running_sessions[session_index]
      if session.buf and vim.api.nvim_buf_is_valid(session.buf) then
        vim.api.nvim_win_set_buf(win, session.buf)
        M.dashboard.windows[session.id] = win
        
        -- Set window title to show session info
        vim.api.nvim_win_set_option(win, "winhighlight", "Normal:Normal")
      end
      session_index = session_index + 1
    end
  end
end

-- Update dashboard with current running sessions
function M.update_dashboard()
  if not M.dashboard.active then
    return
  end
  
  -- Check if we're still in the dashboard tab
  local current_tab = vim.api.nvim_get_current_tabpage()
  if not (M.dashboard.tab_id and vim.api.nvim_tabpage_is_valid(M.dashboard.tab_id)) then
    -- Dashboard tab was closed, disable dashboard
    M.close_dashboard()
    return
  end
  
  -- Get current running sessions
  local running_sessions = {}
  for _, session in pairs(M.sessions) do
    if session.status == "running" then
      table.insert(running_sessions, session)
    end
  end
  
  table.sort(running_sessions, function(a, b)
    return a.started_at < b.started_at
  end)
  
  -- Get currently displayed sessions
  local current_sessions = {}
  for session_id, win in pairs(M.dashboard.windows) do
    if vim.api.nvim_win_is_valid(win) then
      current_sessions[session_id] = true
    else
      -- Window no longer valid, remove from tracking
      M.dashboard.windows[session_id] = nil
    end
  end
  
  -- Check if session set has changed
  local running_session_ids = {}
  for _, session in ipairs(running_sessions) do
    running_session_ids[session.id] = true
  end
  
  -- Compare current vs running sessions
  local sessions_changed = false
  
  -- Check for removed sessions
  for session_id in pairs(current_sessions) do
    if not running_session_ids[session_id] then
      sessions_changed = true
      break
    end
  end
  
  -- Check for new sessions
  if not sessions_changed then
    for session_id in pairs(running_session_ids) do
      if not current_sessions[session_id] then
        sessions_changed = true
        break
      end
    end
  end
  
  -- Only recreate grid if sessions have actually changed
  if sessions_changed then
    -- Switch to dashboard tab and recreate grid
    vim.api.nvim_set_current_tabpage(M.dashboard.tab_id)
    create_dashboard_grid(running_sessions)
  end
end

-- Toggle dashboard visibility
function M.toggle_dashboard()
  if M.dashboard.active then
    M.close_dashboard()
  else
    M.open_dashboard()
  end
end

-- Open dashboard in new tab
function M.open_dashboard()
  if M.dashboard.active then
    -- Switch to existing dashboard tab
    if M.dashboard.tab_id and vim.api.nvim_tabpage_is_valid(M.dashboard.tab_id) then
      vim.api.nvim_set_current_tabpage(M.dashboard.tab_id)
      return
    end
  end
  
  -- Create new tab for dashboard
  vim.cmd("tabnew")
  M.dashboard.tab_id = vim.api.nvim_get_current_tabpage()
  M.dashboard.active = true
  
  -- Set tab name
  vim.api.nvim_tabpage_set_var(M.dashboard.tab_id, "name", "Claude Sessions")
  
  -- Initial dashboard creation
  M.update_dashboard()
  
  -- Set up auto-update timer
  if M.config.dashboard.auto_update then
    M.dashboard.update_timer = vim.fn.timer_start(M.config.dashboard.update_interval, function()
      vim.schedule(M.update_dashboard)
    end, { ["repeat"] = -1 })
  end
  
  vim.notify("Claude Code Dashboard opened", vim.log.levels.INFO)
end

-- Close dashboard
function M.close_dashboard()
  M.dashboard.active = false
  
  -- Stop update timer
  if M.dashboard.update_timer then
    vim.fn.timer_stop(M.dashboard.update_timer)
    M.dashboard.update_timer = nil
  end
  
  -- Close dashboard tab
  if M.dashboard.tab_id and vim.api.nvim_tabpage_is_valid(M.dashboard.tab_id) then
    local current_tab = vim.api.nvim_get_current_tabpage()
    vim.api.nvim_set_current_tabpage(M.dashboard.tab_id)
    vim.cmd("tabclose")
    
    -- Switch back to previous tab if it wasn't the dashboard
    if current_tab ~= M.dashboard.tab_id and vim.api.nvim_tabpage_is_valid(current_tab) then
      vim.api.nvim_set_current_tabpage(current_tab)
    end
  end
  
  M.dashboard.tab_id = nil
  M.dashboard.windows = {}
  
  vim.notify("Claude Code Dashboard closed", vim.log.levels.INFO)
end

-- Get most recent session
function M.get_recent_session()
  local recent = nil
  local recent_time = 0
  
  for id, session in pairs(M.sessions) do
    if session.started_at > recent_time then
      recent = session
      recent_time = session.started_at
    end
  end
  
  return recent
end

-- Attach to most recent session
function M.attach_to_recent()
  local recent = M.get_recent_session()
  if recent then
    M.attach_to_session(recent.id)
  else
    vim.notify("No sessions found", vim.log.levels.INFO)
  end
end

-- Get summary stats for lualine or other integrations
function M.get_stats()
  local stats = {
    total = 0,
    running = 0,
    completed = 0,
    killed = 0,
    active_session = nil,
    last_notification = nil,
  }
  
  for _, session in pairs(M.sessions) do
    stats.total = stats.total + 1
    
    if session.status == "running" then
      stats.running = stats.running + 1
      if not stats.active_session or session.started_at > stats.active_session.started_at then
        stats.active_session = session
      end
    elseif session.status == "completed" then
      stats.completed = stats.completed + 1
    elseif session.status == "killed" then
      stats.killed = stats.killed + 1
    end
    
    if session.last_notification then
      if not stats.last_notification or 
         (session.last_notification_time or session.started_at) > (stats.last_notification_time or 0) then
        stats.last_notification = session.last_notification
        stats.last_notification_time = session.last_notification_time or session.started_at
      end
    end
  end
  
  return stats
end

-- Get current window mode for a session
function M.get_session_window_info(session_id)
  local session = M.sessions[session_id]
  if not session then
    return nil
  end
  
  local info = {
    has_buffer = session.buf and vim.api.nvim_buf_is_valid(session.buf),
    is_visible = false,
    window_id = nil,
  }
  
  if info.has_buffer then
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_buf(win) == session.buf then
        info.is_visible = true
        info.window_id = win
        info.is_float = vim.api.nvim_win_get_config(win).relative ~= ""
        break
      end
    end
  end
  
  return info
end

function M.list_sessions()
  local sessions = {}
  for id, session in pairs(M.sessions) do
    table.insert(sessions, {
      id = id,
      status = session.status,
      started_at = session.started_at,
      args = session.args,
      last_notification = session.last_notification,
      transcript_path = session.transcript_path,
      exit_code = session.exit_code,
    })
  end
  table.sort(sessions, function(a, b) return a.started_at > b.started_at end)
  return sessions
end

function M.attach_to_session(session_id)
  local session = M.sessions[session_id]
  if not session then
    vim.notify("Session not found: " .. session_id, vim.log.levels.ERROR)
    return
  end
  
  -- Check if buffer still exists
  if session.buf and vim.api.nvim_buf_is_valid(session.buf) then
    -- Find or create a window for the buffer
    local win_found = false
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_buf(win) == session.buf then
        vim.api.nvim_set_current_win(win)
        win_found = true
        break
      end
    end
    
    if not win_found then
      -- Open buffer in a new window
      local split_cmd = M.config.terminal.split_direction
      if split_cmd == "float" then
        create_float_window(session.buf)
      else
        local split_size = M.config.terminal.split_size
        
        if split_cmd == "vertical" or split_cmd == "right" then
          local win_width = math.floor(vim.o.columns * split_size)
          if split_cmd == "right" then
            vim.cmd(string.format("rightbelow vertical %dsplit", win_width))
          else
            vim.cmd(string.format("vertical %dsplit", win_width))
          end
        else
          local win_height = math.floor(vim.o.lines * split_size)
          vim.cmd(string.format("%s %dsplit", split_cmd, win_height))
        end
        
        vim.api.nvim_win_set_buf(0, session.buf)
      end
    end
    
    -- Enter insert mode if session is running
    if session.status == "running" then
      vim.cmd("startinsert")
    end
  else
    vim.notify("Session buffer no longer exists", vim.log.levels.WARN)
  end
end

function M.toggle_session(session_id)
  local session = M.sessions[session_id]
  if not session then
    vim.notify("Session not found: " .. session_id, vim.log.levels.ERROR)
    return
  end
  
  if not session.buf or not vim.api.nvim_buf_is_valid(session.buf) then
    vim.notify("Session buffer no longer exists", vim.log.levels.WARN)
    return
  end
  
  -- Check if buffer is visible in any window
  local visible_win = nil
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(win) == session.buf then
      visible_win = win
      break
    end
  end
  
  if visible_win then
    -- Hide the terminal
    vim.api.nvim_win_close(visible_win, false)
  else
    -- Show the terminal
    local split_cmd = M.config.terminal.split_direction
    
    if split_cmd == "float" then
      create_float_window(session.buf)
    else
      local split_size = M.config.terminal.split_size
      
      if split_cmd == "vertical" or split_cmd == "right" then
        local win_width = math.floor(vim.o.columns * split_size)
        if split_cmd == "right" then
          vim.cmd(string.format("rightbelow vertical %dsplit", win_width))
        else
          vim.cmd(string.format("vertical %dsplit", win_width))
        end
      else
        local win_height = math.floor(vim.o.lines * split_size)
        vim.cmd(string.format("%s %dsplit", split_cmd, win_height))
      end
      
      vim.api.nvim_win_set_buf(0, session.buf)
    end
    
    if session.status == "running" and M.config.terminal.start_insert then
      vim.cmd("startinsert")
    end
  end
end

function M.send_to_session(session_id, text)
  local session = M.sessions[session_id]
  if not session then
    vim.notify("Session not found: " .. session_id, vim.log.levels.ERROR)
    return
  end
  
  if session.term_id and session.status == "running" then
    vim.fn.chansend(session.term_id, text)
  else
    vim.notify("Session is not running", vim.log.levels.WARN)
  end
end

function M.kill_session(session_id)
  local session = M.sessions[session_id]
  if not session then
    vim.notify("Session not found: " .. session_id, vim.log.levels.ERROR)
    return
  end
  
  if session.term_id and session.status == "running" then
    vim.fn.jobstop(session.term_id)
    session.status = "killed"
    vim.notify("Killed Claude Code session: " .. session_id, vim.log.levels.INFO)
    
    -- Update dashboard if active
    if M.dashboard.active then
      vim.schedule(function()
        M.update_dashboard()
      end)
    end
  end
  
  -- Clean up hook from settings
  remove_session_hook_from_settings(session_id)
  
  -- Remove hook script files
  local hook_files = vim.fn.glob(M.config.hooks_dir .. "/session_" .. session_id .. "_*.sh", true, true)
  for _, hook_file in ipairs(hook_files) do
    vim.fn.delete(hook_file)
  end
end

function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})
  
  -- Setup enhanced prompt system if enabled
  if M.config.enhanced_prompt.enable_file_suggestions or M.config.enhanced_prompt.enable_prompt_history then
    local has_enhanced_prompt, enhanced_prompt = pcall(require, "multiclaudecode.enhanced_prompt")
    if has_enhanced_prompt then
      enhanced_prompt.setup(M.config.enhanced_prompt)
    end
  end
  
  -- Start notification server
  M.start_notification_server()
  
  -- Load telescope extension if available
  local has_telescope, telescope = pcall(require, "telescope")
  if has_telescope then
    telescope.load_extension("multiclaudecode")
  end
  
  -- Set up lualine refresh if available
  M.setup_lualine_refresh()
  
  -- Create user commands
  vim.api.nvim_create_user_command("ClaudeCodeSpawn", function(opts)
    local args = {}
    if opts.args ~= "" then
      -- Parse arguments
      for arg in opts.args:gmatch("%S+") do
        table.insert(args, arg)
      end
    end
    M.spawn(args)
  end, { nargs = "*", desc = "Spawn a new Claude Code session" })
  
  vim.api.nvim_create_user_command("ClaudeCodeSpawnNoPrompt", function(opts)
    local args = {}
    if opts.args ~= "" then
      -- Parse arguments
      for arg in opts.args:gmatch("%S+") do
        table.insert(args, arg)
      end
    end
    M.spawn_no_prompt(args)
  end, { nargs = "*", desc = "Spawn a new Claude Code session without prompt" })
  
  vim.api.nvim_create_user_command("ClaudeCodeSpawnSafe", function(opts)
    local args = {}
    if opts.args ~= "" then
      -- Parse arguments
      for arg in opts.args:gmatch("%S+") do
        table.insert(args, arg)
      end
    end
    M.spawn_safe(args)
  end, { nargs = "*", desc = "Spawn a new Claude Code session without --dangerously-skip-permissions" })
  
  vim.api.nvim_create_user_command("ClaudeCodeEnhancedSpawn", function(opts)
    local args = {}
    if opts.args ~= "" then
      -- Parse arguments
      for arg in opts.args:gmatch("%S+") do
        table.insert(args, arg)
      end
    end
    M.enhanced_spawn(args)
  end, { nargs = "*", desc = "Spawn a new Claude Code session with enhanced prompt" })
  
  vim.api.nvim_create_user_command("ClaudeCodeCustomInput", function(opts)
    local args = {}
    if opts.args ~= "" then
      -- Parse arguments
      for arg in opts.args:gmatch("%S+") do
        table.insert(args, arg)
      end
    end
    M.spawn_with_custom_input(args)
  end, { nargs = "*", desc = "Spawn a new Claude Code session with custom input (non-Telescope)" })
  
  vim.api.nvim_create_user_command("ClaudeCodeList", function()
    local sessions = M.list_sessions()
    if #sessions == 0 then
      vim.notify("No active Claude Code sessions", vim.log.levels.INFO)
      return
    end
    
    local items = {}
    for _, session in ipairs(sessions) do
      table.insert(items, string.format("[%s] %s - Started: %s", 
        session.status, 
        session.id, 
        os.date("%Y-%m-%d %H:%M:%S", session.started_at)))
    end
    
    vim.ui.select(items, {
      prompt = "Select Claude Code session:",
    }, function(choice, idx)
      if choice then
        M.attach_to_session(sessions[idx].id)
      end
    end)
  end, { desc = "List Claude Code sessions" })
  
  vim.api.nvim_create_user_command("ClaudeCodeTranscript", function(opts)
    local session_id = opts.args
    if session_id == "" then
      -- Show session picker
      local sessions = M.list_sessions()
      local sessions_with_transcript = vim.tbl_filter(function(s) 
        return s.transcript_path ~= nil 
      end, sessions)
      
      if #sessions_with_transcript == 0 then
        vim.notify("No sessions with transcripts found", vim.log.levels.INFO)
        return
      end
      
      local items = {}
      for _, session in ipairs(sessions_with_transcript) do
        table.insert(items, string.format("[%s] %s", 
          session.status, 
          session.id))
      end
      
      vim.ui.select(items, {
        prompt = "Select session transcript to view:",
      }, function(choice, idx)
        if choice then
          local transcript_path = sessions_with_transcript[idx].transcript_path
          if transcript_path then
            vim.cmd("edit " .. vim.fn.fnameescape(vim.fn.expand(transcript_path)))
          end
        end
      end)
    else
      -- Open specific session transcript
      local session = M.sessions[session_id]
      if session and session.transcript_path then
        vim.cmd("edit " .. vim.fn.fnameescape(vim.fn.expand(session.transcript_path)))
      else
        vim.notify("No transcript found for session: " .. session_id, vim.log.levels.ERROR)
      end
    end
  end, { nargs = "?", desc = "View Claude Code session transcript" })
  
  vim.api.nvim_create_user_command("ClaudeCodeToggle", function(opts)
    if opts.args ~= "" then
      M.toggle_session(opts.args)
    else
      -- Show session picker for toggling
      local sessions = M.list_sessions()
      if #sessions == 0 then
        vim.notify("No Claude Code sessions", vim.log.levels.INFO)
        return
      end
      
      local items = {}
      for _, session in ipairs(sessions) do
        table.insert(items, string.format("[%s] %s", 
          session.status, 
          session.id))
      end
      
      vim.ui.select(items, {
        prompt = "Select session to toggle:",
      }, function(choice, idx)
        if choice then
          M.toggle_session(sessions[idx].id)
        end
      end)
    end
  end, { nargs = "?", desc = "Toggle Claude Code session visibility" })
  
  vim.api.nvim_create_user_command("ClaudeCodeTelescope", function()
    local has_telescope, telescope = pcall(require, "telescope")
    if has_telescope then
      telescope.extensions.multiclaudecode.sessions()
    else
      vim.notify("Telescope not found. Please install telescope.nvim", vim.log.levels.ERROR)
    end
  end, { desc = "Open Claude Code sessions in Telescope" })
  
  vim.api.nvim_create_user_command("ClaudeCodeSpawnSelection", function()
    M.spawn_with_selection()
  end, { desc = "Spawn Claude Code with visual selection" })
  
  vim.api.nvim_create_user_command("ClaudeCodeSpawnLine", function()
    M.spawn_with_current_line()
  end, { desc = "Spawn Claude Code with current line" })
  
  vim.api.nvim_create_user_command("ClaudeCodeSpawnFile", function()
    M.spawn_with_file_path()
  end, { desc = "Spawn Claude Code with current file path appended" })
  
  vim.api.nvim_create_user_command("ClaudeCodeAttachRecent", function()
    M.attach_to_recent()
  end, { desc = "Attach to most recent Claude Code session" })
  
  vim.api.nvim_create_user_command("ClaudeCodeSendSelection", function()
    M.send_selection_to_recent()
  end, { range = true, desc = "Send visual selection to recent Claude Code session" })
  
  vim.api.nvim_create_user_command("ClaudeCodeKill", function(opts)
    if opts.args ~= "" then
      M.kill_session(opts.args)
    else
      -- Show session picker
      local sessions = M.list_sessions()
      local running_sessions = vim.tbl_filter(function(s) return s.status == "running" end, sessions)
      
      if #running_sessions == 0 then
        vim.notify("No running Claude Code sessions", vim.log.levels.INFO)
        return
      end
      
      local items = {}
      for _, session in ipairs(running_sessions) do
        table.insert(items, session.id)
      end
      
      vim.ui.select(items, {
        prompt = "Select session to kill:",
      }, function(choice)
        if choice then
          M.kill_session(choice)
        end
      end)
    end
  end, { nargs = "?", desc = "Kill a Claude Code session" })
  
  vim.api.nvim_create_user_command("ClaudeCodeDashboard", function()
    M.open_dashboard()
  end, { desc = "Open Claude Code sessions dashboard" })
  
  vim.api.nvim_create_user_command("ClaudeCodeDashboardOpen", function()
    M.open_dashboard()
  end, { desc = "Open Claude Code sessions dashboard" })
  
  vim.api.nvim_create_user_command("ClaudeCodeDashboardClose", function()
    M.close_dashboard()
  end, { desc = "Close Claude Code sessions dashboard" })
  
  -- Set up keymaps
  M.setup_keymaps()
end

function M.setup_keymaps()
  local keymaps = M.config.keymaps
  if not keymaps then
    return
  end
  
  -- Normal mode mappings
  if keymaps.spawn then
    vim.keymap.set("n", keymaps.spawn, function()
      M.enhanced_spawn()
    end, { desc = "Spawn Claude Code session with enhanced prompt" })
  end
  
  if keymaps.spawn_with_selection then
    -- Visual mode mapping for selection
    vim.keymap.set("v", keymaps.spawn_with_selection, function()
      M.spawn_with_selection()
    end, { desc = "Spawn Claude Code with selection" })
    
    -- Normal mode mapping for current line
    vim.keymap.set("n", keymaps.spawn_with_selection, function()
      M.spawn_with_current_line()
    end, { desc = "Spawn Claude Code with current line" })
  end
  
  if keymaps.toggle then
    vim.keymap.set("n", keymaps.toggle, function()
      local recent = M.get_recent_session()
      if recent then
        M.toggle_session(recent.id)
      else
        vim.notify("No sessions found", vim.log.levels.INFO)
      end
    end, { desc = "Toggle recent Claude Code session" })
  end
  
  if keymaps.kill then
    vim.keymap.set("n", keymaps.kill, function()
      local recent = M.get_recent_session()
      if recent and recent.status == "running" then
        M.kill_session(recent.id)
      else
        vim.notify("No running sessions found", vim.log.levels.INFO)
      end
    end, { desc = "Kill recent Claude Code session" })
  end
  
  if keymaps.list then
    vim.keymap.set("n", keymaps.list, function()
      local has_telescope, telescope = pcall(require, "telescope")
      if has_telescope then
        telescope.extensions.multiclaudecode.sessions()
      else
        vim.cmd("ClaudeCodeList")
      end
    end, { desc = "List Claude Code sessions" })
  end
  
  if keymaps.attach then
    vim.keymap.set("n", keymaps.attach, function()
      M.attach_to_recent()
    end, { desc = "Attach to recent Claude Code session" })
    
    -- Visual mode mapping for sending selection to recent session
    vim.keymap.set("v", keymaps.attach, function()
      M.send_selection_to_recent()
    end, { desc = "Send selection to recent Claude Code session" })
  end
  
  if keymaps.enhanced_spawn then
    vim.keymap.set("n", keymaps.enhanced_spawn, function()
      M.enhanced_spawn()
    end, { desc = "Enhanced spawn with file suggestions and prompt history" })
  end
  
  if keymaps.spawn_no_prompt then
    vim.keymap.set("n", keymaps.spawn_no_prompt, function()
      M.spawn_no_prompt()
    end, { desc = "Spawn Claude Code session without prompt" })
  end
  
  if keymaps.spawn_safe then
    vim.keymap.set("n", keymaps.spawn_safe, function()
      M.spawn_safe()
    end, { desc = "Spawn Claude Code session without --dangerously-skip-permissions" })
  end
  
  if keymaps.custom_input_spawn then
    vim.keymap.set("n", keymaps.custom_input_spawn, function()
      M.spawn_with_custom_input()
    end, { desc = "Spawn Claude Code with custom input (@ file mentions)" })
  end
  
  if keymaps.dashboard then
    vim.keymap.set("n", keymaps.dashboard, function()
      M.open_dashboard()
    end, { desc = "Open Claude Code sessions dashboard" })
  end
  
  if keymaps.dashboard_close then
    vim.keymap.set("n", keymaps.dashboard_close, function()
      M.close_dashboard()
    end, { desc = "Close Claude Code sessions dashboard" })
  end
end

function M.setup_lualine_refresh()
  -- Check if lualine is enabled and available
  if not M.config.lualine.enabled then
    return
  end
  
  local has_lualine, lualine = pcall(require, "lualine")
  if not has_lualine then
    return
  end
  
  -- Set up autocmd to refresh lualine when sessions change
  local group = vim.api.nvim_create_augroup("MultiClaudeCodeLualine", { clear = true })
  
  -- Refresh lualine when entering/leaving terminal buffers
  vim.api.nvim_create_autocmd({ "BufEnter", "BufLeave", "TermClose" }, {
    group = group,
    pattern = "term://*",
    callback = function()
      -- Check if this is a Claude Code terminal
      local buf_name = vim.api.nvim_buf_get_name(0)
      if buf_name:match("ClaudeCode:") then
        vim.schedule(function()
          lualine.refresh()
        end)
      end
    end,
  })
  
  -- Also refresh periodically for running sessions
  local refresh_rate = M.config.lualine.refresh_rate or 5000
  local timer = vim.loop.new_timer()
  timer:start(0, refresh_rate, vim.schedule_wrap(function()
    local has_running = false
    for _, session in pairs(M.sessions) do
      if session.status == "running" then
        has_running = true
        break
      end
    end
    
    if has_running then
      lualine.refresh({ place = { "statusline" } })
    end
  end))
end

function M.start_notification_server()
  local notifications = require("multiclaudecode.notifications")
  local port = M.config.notification_port or 9999
  M.notification_server_port = port
  
  M.notification_server = notifications.create_notification_server(port, function(data)
    local session_id = data.session_id
    local session = M.sessions[session_id]
    
    if not session then
      return
    end
    
    -- Handle different event types
    if data.hook_event_name == "Notification" then
      -- Claude Code notification with message
      if data.message then
        session.last_notification = data.message
        session.last_notification_time = os.time()
        vim.schedule(function()
          vim.notify(string.format("[%s] %s", session_id:sub(1, 8), data.message), 
            vim.log.levels.INFO, { title = "Claude Code" })
          
          -- Refresh lualine if available
          local has_lualine, lualine = pcall(require, "lualine")
          if has_lualine then
            lualine.refresh({ place = { "statusline" } })
          end
        end)
      end
      
      -- Store transcript path if provided
      if data.transcript_path then
        session.transcript_path = data.transcript_path
      end
    elseif data.hook_event_name == "PostToolUse" then
      -- Tool use completed
      session.last_tool_use = os.time()
    end
  end)
end

-- Get lualine component for easy integration
function M.get_lualine_component(opts)
  local lualine_module = require("multiclaudecode.lualine")
  return lualine_module.get_component(opts)
end

return M
