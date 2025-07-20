local M = {}

local telescope = require("telescope")
local actions = require("telescope.actions")
local action_state = require("telescope.actions.state")
local pickers = require("telescope.pickers")
local finders = require("telescope.finders")
local conf = require("telescope.config").values
local entry_display = require("telescope.pickers.entry_display")
local previewers = require("telescope.previewers")

local multiclaudecode = require("multiclaudecode")

-- Auto-refresh timer
local refresh_timer = nil

local function stop_refresh_timer()
  if refresh_timer then
    vim.fn.timer_stop(refresh_timer)
    refresh_timer = nil
  end
end

local function make_entry(session)
  local displayer = entry_display.create({
    separator = " │ ",
    items = {
      { width = 10 },  -- Status
      { width = 15 },  -- Session ID (shortened)
      { width = 8 },   -- Time
      { width = 12 },  -- Duration/Exit code
      { remaining = true },  -- Last notification
    },
  })
  
  local function make_display(entry)
    local status_icon = ""
    local status_hl = "TelescopeResultsComment"
    
    if entry.status == "running" then
      status_icon = "● running"
      status_hl = "DiagnosticOk"
    elseif entry.status == "completed" then
      status_icon = "✓ done"
      status_hl = "DiagnosticHint"
    elseif entry.status == "killed" then
      status_icon = "✗ killed"
      status_hl = "DiagnosticError"
    end
    
    local time_str = os.date("%H:%M:%S", entry.started_at)
    
    local duration_str = ""
    if entry.status == "running" then
      local duration = os.time() - entry.started_at
      local hours = math.floor(duration / 3600)
      local mins = math.floor((duration % 3600) / 60)
      local secs = duration % 60
      if hours > 0 then
        duration_str = string.format("%dh %dm", hours, mins)
      elseif mins > 0 then
        duration_str = string.format("%dm %ds", mins, secs)
      else
        duration_str = string.format("%ds", secs)
      end
    elseif entry.exit_code then
      duration_str = "exit: " .. entry.exit_code
    end
    
    local notification = entry.last_notification or "Waiting..."
    if #notification > 50 then
      notification = notification:sub(1, 47) .. "..."
    end
    
    return displayer({
      { status_icon, status_hl },
      { entry.id:sub(1, 15) },
      { time_str },
      { duration_str, "TelescopeResultsComment" },
      { notification, "TelescopeResultsFunction" },
    })
  end
  
  return {
    value = session,
    display = make_display,
    ordinal = session.id .. " " .. session.status .. " " .. (session.last_notification or ""),
    id = session.id,
    status = session.status,
    started_at = session.started_at,
    exit_code = session.exit_code,
    last_notification = session.last_notification,
    transcript_path = session.transcript_path,
    args = session.args,
  }
end

local function create_previewer()
  return previewers.new_buffer_previewer({
    title = "Session Details",
    define_preview = function(self, entry)
      local session = multiclaudecode.sessions[entry.id]
      if not session then
        return
      end
      
      -- Clear the preview buffer
      vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, {})
      
      -- If we have a valid terminal buffer, show its content
      if session.buf and vim.api.nvim_buf_is_valid(session.buf) then
        -- Get terminal buffer content
        local term_lines = vim.api.nvim_buf_get_lines(session.buf, 0, -1, false)
        
        -- Add header
        local header_lines = {
          "╭─ Session: " .. entry.id .. " ─╮",
          "│ Status: " .. entry.status .. " │ Started: " .. os.date("%H:%M:%S", entry.started_at),
          "╰" .. string.rep("─", 50) .. "╯",
          "",
        }
        
        -- Add last notification if available
        if entry.last_notification then
          table.insert(header_lines, "📢 " .. entry.last_notification)
          table.insert(header_lines, "")
        end
        
        -- Combine header and terminal content
        local all_lines = {}
        vim.list_extend(all_lines, header_lines)
        vim.list_extend(all_lines, term_lines)
        
        -- Set content
        vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, all_lines)
        
        -- Add highlights for header
        vim.api.nvim_buf_add_highlight(self.state.bufnr, -1, "TelescopePreviewBorder", 0, 0, -1)
        vim.api.nvim_buf_add_highlight(self.state.bufnr, -1, "TelescopePreviewTitle", 1, 0, -1)
        vim.api.nvim_buf_add_highlight(self.state.bufnr, -1, "TelescopePreviewBorder", 2, 0, -1)
        
        if entry.last_notification then
          vim.api.nvim_buf_add_highlight(self.state.bufnr, -1, "DiagnosticInfo", 4, 0, 2)
        end
        
        -- Set terminal-like options for preview
        vim.api.nvim_buf_set_option(self.state.bufnr, "wrap", false)
        vim.api.nvim_buf_set_option(self.state.bufnr, "number", false)
        vim.api.nvim_buf_set_option(self.state.bufnr, "relativenumber", false)
      else
        -- Fallback to simple info if no terminal buffer
        local lines = {
          "Session ID: " .. entry.id,
          "Status: " .. entry.status,
          "Started: " .. os.date("%Y-%m-%d %H:%M:%S", entry.started_at),
          "",
          "No terminal buffer available",
        }
        vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, lines)
      end
    end,
  })
end

function M.sessions_picker(opts)
  opts = opts or {}
  
  stop_refresh_timer()
  
  local sessions = multiclaudecode.list_sessions()
  
  if #sessions == 0 then
    vim.notify("No Claude Code sessions found", vim.log.levels.INFO)
    return
  end
  
  local picker = pickers.new(opts, {
    prompt_title = "Claude Code Sessions",
    finder = finders.new_table({
      results = sessions,
      entry_maker = make_entry,
    }),
    sorter = conf.generic_sorter(opts),
    previewer = create_previewer(),
    attach_mappings = function(prompt_bufnr, map)
      local function refresh_picker()
        local current_picker = action_state.get_current_picker(prompt_bufnr)
        local new_sessions = multiclaudecode.list_sessions()
        current_picker:refresh(finders.new_table({
          results = new_sessions,
          entry_maker = make_entry,
        }), opts)
      end
      
      -- Set up auto-refresh for running sessions
      local has_running = false
      for _, session in ipairs(sessions) do
        if session.status == "running" then
          has_running = true
          break
        end
      end
      
      if has_running then
        refresh_timer = vim.fn.timer_start(2000, function()
          vim.schedule(refresh_picker)
        end, { ["repeat"] = -1 })
      end
      
      local function attach_to_session()
        local selection = action_state.get_selected_entry()
        if selection then
          stop_refresh_timer()
          actions.close(prompt_bufnr)
          -- Close existing session windows before attaching to selected session
          -- BUT exclude dashboard windows when dashboard is active
          for session_id, session in pairs(multiclaudecode.sessions) do
            if session.buf and vim.api.nvim_buf_is_valid(session.buf) then
              for _, win in ipairs(vim.api.nvim_list_wins()) do
                if vim.api.nvim_win_get_buf(win) == session.buf then
                  -- If dashboard is active, don't close windows that are part of the dashboard
                  if multiclaudecode.dashboard.active and multiclaudecode.dashboard.windows[session_id] == win then
                    -- Skip closing this window as it's part of the dashboard
                  else
                    vim.api.nvim_win_close(win, false)
                  end
                end
              end
            end
          end
          multiclaudecode.attach_to_session(selection.id)
        end
      end
      
      local function kill_session()
        local selection = action_state.get_selected_entry()
        if selection then
          if selection.status == "running" then
            multiclaudecode.kill_session(selection.id)
            refresh_picker()
          else
            vim.notify("Session is not running", vim.log.levels.WARN)
          end
        end
      end
      
      local function view_transcript()
        local selection = action_state.get_selected_entry()
        if selection then
          if selection.transcript_path then
            stop_refresh_timer()
            actions.close(prompt_bufnr)
            vim.cmd("edit " .. vim.fn.fnameescape(vim.fn.expand(selection.transcript_path)))
          else
            vim.notify("No transcript available for this session", vim.log.levels.WARN)
          end
        end
      end
      
      local function spawn_new_session()
        stop_refresh_timer()
        actions.close(prompt_bufnr)
        vim.ui.input({
          prompt = "Claude Code arguments: ",
          default = "",
        }, function(input)
          if input then
            local args = {}
            for arg in input:gmatch("%S+") do
              table.insert(args, arg)
            end
            multiclaudecode.spawn(args)
            -- Reopen telescope after spawning
            vim.defer_fn(function()
              M.sessions_picker(opts)
            end, 100)
          end
        end)
      end
      
      local function toggle_session()
        local selection = action_state.get_selected_entry()
        if selection then
          -- Close existing session windows before toggling selected session
          -- BUT exclude dashboard windows when dashboard is active
          for session_id, session in pairs(multiclaudecode.sessions) do
            if session_id ~= selection.id and session.buf and vim.api.nvim_buf_is_valid(session.buf) then
              for _, win in ipairs(vim.api.nvim_list_wins()) do
                if vim.api.nvim_win_get_buf(win) == session.buf then
                  -- If dashboard is active, don't close windows that are part of the dashboard
                  if multiclaudecode.dashboard.active and multiclaudecode.dashboard.windows[session_id] == win then
                    -- Skip closing this window as it's part of the dashboard
                  else
                    vim.api.nvim_win_close(win, false)
                  end
                end
              end
            end
          end
          multiclaudecode.toggle_session(selection.id)
          refresh_picker()
        end
      end
      
      local function refresh_manual()
        refresh_picker()
      end
      
      actions.select_default:replace(attach_to_session)
      map("i", "<C-k>", kill_session)
      map("n", "k", kill_session)
      map("i", "<C-t>", view_transcript)
      map("n", "t", view_transcript)
      map("i", "<C-n>", spawn_new_session)
      map("n", "n", spawn_new_session)
      map("i", "<C-r>", refresh_manual)
      map("n", "r", refresh_manual)
      map("i", "<C-v>", toggle_session)
      map("n", "v", toggle_session)
      
      -- Clean up timer on close
      map("i", "<Esc>", function()
        stop_refresh_timer()
        actions.close(prompt_bufnr)
      end)
      map("n", "<Esc>", function()
        stop_refresh_timer()
        actions.close(prompt_bufnr)
      end)
      map("n", "q", function()
        stop_refresh_timer()
        actions.close(prompt_bufnr)
      end)
      
      return true
    end,
    initial_mode = "insert",
  })
  
  picker:find()
end

return M