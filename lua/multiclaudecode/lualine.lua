local M = {}

local multiclaudecode = require("multiclaudecode")

-- Lualine component for Claude Code sessions
function M.status()
  local sessions = multiclaudecode.list_sessions()
  if #sessions == 0 then
    return ""
  end
  
  local running = 0
  local completed = 0
  local last_notification = nil
  
  for _, session in ipairs(sessions) do
    if session.status == "running" then
      running = running + 1
      if session.last_notification then
        last_notification = session.last_notification
      end
    elseif session.status == "completed" then
      completed = completed + 1
    end
  end
  
  local parts = {}
  
  if running > 0 then
    table.insert(parts, string.format("🤖 %d", running))
  end
  
  if completed > 0 then
    table.insert(parts, string.format("✓ %d", completed))
  end
  
  if #parts == 0 then
    return ""
  end
  
  local status = table.concat(parts, " ")
  
  -- Add last notification preview if available
  if last_notification and #last_notification > 20 then
    last_notification = last_notification:sub(1, 20) .. "..."
  end
  
  if last_notification then
    status = status .. " │ " .. last_notification
  end
  
  return status
end

-- Detailed component with click support
function M.detailed_status()
  local sessions = multiclaudecode.list_sessions()
  if #sessions == 0 then
    return ""
  end
  
  local stats = {
    running = 0,
    completed = 0,
    killed = 0,
    total = #sessions,
  }
  
  local active_session = nil
  
  for _, session in ipairs(sessions) do
    if session.status == "running" then
      stats.running = stats.running + 1
      if not active_session then
        active_session = session
      end
    elseif session.status == "completed" then
      stats.completed = stats.completed + 1
    elseif session.status == "killed" then
      stats.killed = stats.killed + 1
    end
  end
  
  -- Build status string
  local parts = {}
  
  -- Icon based on state
  local icon = "🤖"
  if stats.running == 0 then
    icon = "💤"
  elseif stats.running > 1 then
    icon = "🤖×" .. stats.running
  end
  
  table.insert(parts, icon)
  
  -- Show active session info
  if active_session then
    local duration = os.time() - active_session.started_at
    local duration_str = ""
    
    if duration < 60 then
      duration_str = duration .. "s"
    elseif duration < 3600 then
      duration_str = math.floor(duration / 60) .. "m"
    else
      duration_str = math.floor(duration / 3600) .. "h"
    end
    
    table.insert(parts, duration_str)
    
    if active_session.last_notification then
      local msg = active_session.last_notification
      if #msg > 15 then
        msg = msg:sub(1, 15) .. "…"
      end
      table.insert(parts, msg)
    end
  else
    -- Show summary
    table.insert(parts, string.format("%d/%d", stats.completed, stats.total))
  end
  
  return table.concat(parts, " ")
end

-- Get component configuration for lualine
function M.get_component(opts)
  opts = opts or {}
  
  -- Get config from multiclaudecode
  local config = multiclaudecode.config and multiclaudecode.config.lualine or {}
  
  -- Determine which status function to use
  local status_func = M.detailed_status
  if config.component_type == "simple" then
    status_func = M.status
  end
  
  return {
    function()
      return status_func()
    end,
    icon = "",  -- Icon is included in the status
    color = function()
      local sessions = multiclaudecode.list_sessions()
      local has_running = false
      
      for _, session in ipairs(sessions) do
        if session.status == "running" then
          has_running = true
          break
        end
      end
      
      local colors = config.colors or {}
      if has_running then
        return { fg = colors.running or "#50fa7b", bg = nil }  -- Green for running
      else
        return { fg = colors.idle or "#6272a4", bg = nil }  -- Gray for idle
      end
    end,
    on_click = function()
      -- Open telescope picker on click
      local has_telescope, telescope = pcall(require, "telescope")
      if has_telescope then
        telescope.extensions.multiclaudecode.sessions()
      else
        vim.cmd("ClaudeCodeList")
      end
    end,
  }
end

return M