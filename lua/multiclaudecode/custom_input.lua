-- Custom input module with @ file mention support (non-Telescope)
local M = {}

local file_discovery = require("multiclaudecode.file_discovery")

-- Internal state
local prompt_history = {}
local current_completions = {}
local completion_index = 0
local original_prompt = ""

-- Add to prompt history
local function add_to_history(prompt)
  if not prompt or prompt == "" then
    return
  end
  
  -- Remove duplicates
  for i = #prompt_history, 1, -1 do
    if prompt_history[i] == prompt then
      table.remove(prompt_history, i)
    end
  end
  
  -- Add to beginning
  table.insert(prompt_history, 1, prompt)
  
  -- Limit history size
  if #prompt_history > 100 then
    table.remove(prompt_history, #prompt_history)
  end
end

-- Get file completions for a given query
local function get_file_completions(query)
  local current_file_info = file_discovery.get_current_buffer_info()
  local current_file = current_file_info and current_file_info.filepath or nil
  
  if not query or query == "" then
    local recent = file_discovery.get_recent_files(20)
    -- Filter out current file
    local filtered = {}
    for _, file in ipairs(recent) do
      if not current_file or file.filepath ~= current_file then
        table.insert(filtered, file)
      end
    end
    return filtered
  end
  
  local results = file_discovery.search_files(query)
  -- Filter out current file and limit results
  local limited = {}
  for i = 1, math.min(20, #results) do
    if not current_file or results[i].filepath ~= current_file then
      table.insert(limited, results[i])
    end
  end
  return limited
end

-- Parse @ mentions in the prompt
local function parse_mentions(prompt)
  local mentions = {}
  local pattern = "@([%w%p%-_/%.]+)"
  
  for match in prompt:gmatch(pattern) do
    table.insert(mentions, match)
  end
  
  return mentions
end

-- Create completion popup window
local function create_completion_window(completions, current_line)
  if #completions == 0 then
    return nil
  end
  
  -- Prepare completion items
  local lines = {}
  local max_width = 0
  
  for i, completion in ipairs(completions) do
    local prefix = i == completion_index and "▶ " or "  "
    local line = prefix .. completion.relative_path
    table.insert(lines, line)
    max_width = math.max(max_width, #line)
  end
  
  -- Create buffer
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_buf_set_option(buf, 'modifiable', false)
  vim.api.nvim_buf_set_option(buf, 'buftype', 'nofile')
  
  -- Calculate window position (below current line)
  local cursor = vim.api.nvim_win_get_cursor(0)
  local win_height = math.min(#lines, 10)
  local win_width = math.min(max_width + 2, 60)
  
  -- Get window position
  local win_pos = vim.api.nvim_win_get_position(0)
  local win_config = {
    relative = 'win',
    row = cursor[1] - win_pos[1] + 1,
    col = cursor[2],
    width = win_width,
    height = win_height,
    style = 'minimal',
    border = 'single',
  }
  
  -- Create window
  local win = vim.api.nvim_open_win(buf, false, win_config)
  
  -- Highlight current selection
  vim.api.nvim_buf_add_highlight(buf, -1, 'PmenuSel', completion_index - 1, 0, -1)
  
  return win, buf
end

-- Custom input function with @ completion
function M.input_with_completion(opts, on_confirm)
  opts = opts or {}
  
  -- Create a new buffer for input
  local input_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_option(input_buf, 'buftype', 'prompt')
  vim.api.nvim_buf_set_option(input_buf, 'bufhidden', 'wipe')
  
  -- Set prompt
  local prompt = opts.prompt or "Claude Code prompt: "
  vim.fn.prompt_setprompt(input_buf, prompt)
  
  -- Calculate window size and position
  local width = math.floor(vim.o.columns * 0.6)
  local height = 1
  local row = math.floor((vim.o.lines - height) / 2)
  local col = math.floor((vim.o.columns - width) / 2)
  
  -- Create floating window
  local win_opts = {
    relative = 'editor',
    width = width,
    height = height,
    row = row,
    col = col,
    style = 'minimal',
    border = 'rounded',
    title = ' Claude Code Custom Input ',
    title_pos = 'center',
  }
  
  local input_win = vim.api.nvim_open_win(input_buf, true, win_opts)
  
  -- State for completion
  local completion_win = nil
  local completion_buf = nil
  local in_completion = false
  local history_index = 0
  
  -- Function to close completion window
  local function close_completion()
    if completion_win and vim.api.nvim_win_is_valid(completion_win) then
      vim.api.nvim_win_close(completion_win, true)
    end
    completion_win = nil
    completion_buf = nil
    current_completions = {}
    completion_index = 0
    in_completion = false
  end
  
  -- Function to update completion
  local function update_completion()
    local line = vim.api.nvim_get_current_line()
    
    -- Find @ symbol before cursor
    local cursor_pos = vim.api.nvim_win_get_cursor(0)[2]
    local before_cursor = line:sub(1, cursor_pos)
    
    -- Look for @ followed by word characters
    local at_pos = before_cursor:match(".*()@[%w%p%-_/%.]*$")
    
    if at_pos then
      -- Extract the query after @
      local query = before_cursor:sub(at_pos + 1)
      
      -- Get file completions
      current_completions = get_file_completions(query)
      
      if #current_completions > 0 then
        completion_index = 1
        close_completion()
        completion_win, completion_buf = create_completion_window(current_completions, line)
        in_completion = true
      else
        close_completion()
      end
    else
      close_completion()
    end
  end
  
  -- Function to accept completion
  local function accept_completion()
    if not in_completion or completion_index == 0 or #current_completions == 0 then
      return false
    end
    
    local completion = current_completions[completion_index]
    if not completion then
      return false
    end
    
    local line = vim.api.nvim_get_current_line()
    local cursor_pos = vim.api.nvim_win_get_cursor(0)[2]
    local before_cursor = line:sub(1, cursor_pos)
    
    -- Find the @ position
    local at_pos = before_cursor:match(".*()@[%w%p%-_/%.]*$")
    if at_pos then
      -- Replace @ and query with the completed file path
      local new_line = before_cursor:sub(1, at_pos - 1) .. completion.relative_path .. line:sub(cursor_pos + 1)
      vim.api.nvim_set_current_line(new_line)
      
      -- Move cursor to end of completion
      local new_cursor_pos = at_pos - 1 + #completion.relative_path
      vim.api.nvim_win_set_cursor(0, {1, new_cursor_pos})
    end
    
    close_completion()
    return true
  end
  
  -- Set up keymaps
  local function setup_keymaps()
    -- Tab for completion navigation
    vim.keymap.set('i', '<Tab>', function()
      if in_completion and #current_completions > 0 then
        completion_index = completion_index % #current_completions + 1
        if completion_win and completion_buf then
          -- Update highlight
          vim.api.nvim_buf_clear_namespace(completion_buf, -1, 0, -1)
          vim.api.nvim_buf_add_highlight(completion_buf, -1, 'PmenuSel', completion_index - 1, 0, -1)
        end
      else
        -- Trigger completion check
        update_completion()
      end
    end, { buffer = input_buf })
    
    -- Shift-Tab for reverse navigation
    vim.keymap.set('i', '<S-Tab>', function()
      if in_completion and #current_completions > 0 then
        completion_index = completion_index - 1
        if completion_index < 1 then
          completion_index = #current_completions
        end
        if completion_win and completion_buf then
          -- Update highlight
          vim.api.nvim_buf_clear_namespace(completion_buf, -1, 0, -1)
          vim.api.nvim_buf_add_highlight(completion_buf, -1, 'PmenuSel', completion_index - 1, 0, -1)
        end
      end
    end, { buffer = input_buf })
    
    -- Enter to accept completion or submit
    vim.keymap.set('i', '<CR>', function()
      if in_completion and not accept_completion() then
        -- If no completion was accepted, treat as submit
        local line = vim.api.nvim_get_current_line()
        close_completion()
        vim.api.nvim_win_close(input_win, true)
        add_to_history(line)
        on_confirm(line)
      elseif not in_completion then
        -- Normal submit
        local line = vim.api.nvim_get_current_line()
        close_completion()
        vim.api.nvim_win_close(input_win, true)
        add_to_history(line)
        on_confirm(line)
      end
    end, { buffer = input_buf })
    
    -- Escape to cancel
    vim.keymap.set('i', '<Esc>', function()
      close_completion()
      vim.api.nvim_win_close(input_win, true)
      on_confirm(nil)
    end, { buffer = input_buf })
    
    -- Up/Down for history navigation
    vim.keymap.set('i', '<Up>', function()
      if not in_completion and #prompt_history > 0 then
        history_index = math.min(history_index + 1, #prompt_history)
        if history_index > 0 then
          vim.api.nvim_set_current_line(prompt_history[history_index])
          -- Move cursor to end of line
          local line_len = #prompt_history[history_index]
          vim.api.nvim_win_set_cursor(0, {1, line_len})
        end
      end
    end, { buffer = input_buf })
    
    vim.keymap.set('i', '<Down>', function()
      if not in_completion then
        history_index = math.max(history_index - 1, 0)
        if history_index > 0 and history_index <= #prompt_history then
          vim.api.nvim_set_current_line(prompt_history[history_index])
          -- Move cursor to end of line
          local line_len = #prompt_history[history_index]
          vim.api.nvim_win_set_cursor(0, {1, line_len})
        elseif history_index == 0 then
          vim.api.nvim_set_current_line("")
        end
      end
    end, { buffer = input_buf })
    
    -- @ trigger for completion
    vim.keymap.set('i', '@', function()
      vim.api.nvim_feedkeys('@', 'n', false)
      vim.schedule(update_completion)
    end, { buffer = input_buf })
    
    -- Regular typing updates
    vim.api.nvim_create_autocmd({"TextChangedI"}, {
      buffer = input_buf,
      callback = function()
        if in_completion then
          update_completion()
        end
      end,
    })
  end
  
  setup_keymaps()
  
  -- Start in insert mode
  vim.cmd('startinsert!')
  
  -- Set default text if provided
  if opts.default and opts.default ~= "" then
    vim.api.nvim_set_current_line(opts.default)
    local line_len = #opts.default
    vim.api.nvim_win_set_cursor(0, {1, line_len})
  end
end

-- Process file mentions in the final prompt
function M.process_file_mentions(prompt)
  local processed = prompt
  local files_content = {}
  
  -- Find all @ mentions
  local mentions = parse_mentions(prompt)
  
  for _, mention in ipairs(mentions) do
    -- Search for the file
    local results = file_discovery.search_files(mention)
    
    if #results > 0 then
      local file = results[1]  -- Take the best match
      
      -- Read file content
      local content = ""
      local file_handle = io.open(file.filepath, "r")
      if file_handle then
        content = file_handle:read("*all")
        file_handle:close()
        
        -- Add file content to collection
        table.insert(files_content, {
          path = file.relative_path,
          content = content,
          extension = file.extension,
        })
        
        -- Replace @mention with file path
        processed = processed:gsub("@" .. vim.pesc(mention), file.relative_path)
      end
    end
  end
  
  -- If we have file contents, append them to the prompt
  if #files_content > 0 then
    processed = processed .. "\n\n--- File Context ---"
    
    for _, file in ipairs(files_content) do
      processed = processed .. string.format("\n\n**%s**\n```%s\n%s\n```",
        file.path,
        file.extension ~= "" and file.extension or "text",
        file.content
      )
    end
  end
  
  return processed
end

-- Public API function for spawning with custom input
function M.spawn_with_custom_input(multiclaudecode_instance, args)
  M.input_with_completion({
    prompt = "Claude Code prompt (use @ for files): ",
    default = "",
  }, function(input)
    if not input or input == "" then
      return
    end
    
    -- Process @ mentions to include file contents
    local processed_message = M.process_file_mentions(input)
    
    -- Get current file path for appending
    local filepath = vim.fn.expand("%:p")
    if filepath ~= "" then
      if processed_message ~= "" then
        processed_message = processed_message .. " " .. filepath
      else
        processed_message = filepath
      end
    end
    
    -- Spawn with processed message
    local spawn_args = vim.tbl_deep_extend("force", args or {}, { message = processed_message })
    multiclaudecode_instance.spawn_with_message(processed_message, spawn_args)
  end)
end

-- Get prompt history
function M.get_history()
  return prompt_history
end

-- Clear prompt history
function M.clear_history()
  prompt_history = {}
end

return M