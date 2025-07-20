-- Enhanced prompt system with file suggestions and auto-completion
local M = {}

local file_discovery = require("multiclaudecode.file_discovery")
local telescope = require("telescope")
local pickers = require("telescope.pickers")
local finders = require("telescope.finders")
local conf = require("telescope.config").values
local actions = require("telescope.actions")
local action_state = require("telescope.actions.state")
local entry_display = require("telescope.pickers.entry_display")

-- Configuration
M.config = {
  enable_file_suggestions = true,
  enable_prompt_history = true,
  max_history_entries = 100,
  suggestion_trigger = "@",
  file_trigger = "file:",
  auto_trigger_chars = { "@", ":", "/" },
  show_recent_files = true,
  show_git_files = true,
  max_suggestions = 20,
}

-- Internal state
local prompt_history = {}
local current_suggestions = {}

-- File path completion helper
local function get_file_completions(query)
  if not query or query == "" then
    return file_discovery.get_recent_files(M.config.max_suggestions)
  end
  
  return file_discovery.search_files(query)
end

-- History management
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
  if #prompt_history > M.config.max_history_entries then
    table.remove(prompt_history, #prompt_history)
  end
end

-- Get prompt history
function M.get_prompt_history()
  return prompt_history
end

-- Enhanced input with file suggestions
function M.enhanced_input(opts, callback)
  opts = opts or {}
  
  -- Use telescope for enhanced input
  local function create_finder(query)
    query = query or ""
    local results = {}
    
    -- Add prompt history
    if M.config.enable_prompt_history then
      for i, entry in ipairs(prompt_history) do
        if entry:lower():find(query:lower(), 1, true) then
          table.insert(results, {
            type = "history",
            text = entry,
            display = "📝 " .. entry,
            value = entry,
            ordinal = entry,
            priority = 100 - i,
          })
        end
      end
    end
    
    -- Add current buffer context
    local current_file = file_discovery.get_current_buffer_info()
    if current_file then
      table.insert(results, {
        type = "current_file",
        text = current_file.relative_path,
        display = "📄 Current file: " .. current_file.relative_path,
        value = current_file.relative_path,
        ordinal = current_file.relative_path,
        priority = 90,
      })
    end
    
    -- Add file suggestions if enabled
    if M.config.enable_file_suggestions then
      local file_query = query
      local trigger_pos = query:find(M.config.suggestion_trigger)
      
      if trigger_pos then
        file_query = query:sub(trigger_pos + 1)
      end
      
      local files = get_file_completions(file_query)
      for _, file in ipairs(files) do
        table.insert(results, {
          type = "file",
          text = file.relative_path,
          display = "📁 " .. file.relative_path,
          value = file.relative_path,
          ordinal = file.relative_path,
          priority = 50,
          file_info = file,
        })
      end
    end
    
    -- Sort by priority and relevance
    table.sort(results, function(a, b)
      return a.priority > b.priority
    end)
    
    return results
  end
  
  local function make_entry(result)
    return {
      value = result,
      display = result.display,
      ordinal = result.ordinal,
    }
  end
  
  local picker = pickers.new(opts, {
    prompt_title = opts.prompt or "Claude Code Enhanced Prompt",
    finder = finders.new_dynamic({
      fn = function(prompt)
        return create_finder(prompt)
      end,
      entry_maker = make_entry,
    }),
    sorter = conf.generic_sorter(opts),
    attach_mappings = function(prompt_bufnr, map)
      local function select_suggestion()
        local selection = action_state.get_selected_entry()
        if selection then
          local current_line = action_state.get_current_line()
          local new_text = selection.value.value
          
          -- Handle different suggestion types
          if selection.value.type == "file" then
            -- For file suggestions, replace the trigger and query
            local trigger_pos = current_line:find(M.config.suggestion_trigger)
            if trigger_pos then
              new_text = current_line:sub(1, trigger_pos - 1) .. new_text
            else
              new_text = current_line .. " " .. new_text
            end
          elseif selection.value.type == "history" then
            new_text = selection.value.text
          end
          
          actions.close(prompt_bufnr)
          
          -- Add to history
          add_to_history(new_text)
          
          -- Call the callback with the selected text
          callback(new_text)
        end
      end
      
      actions.select_default:replace(select_suggestion)
      
      return true
    end,
    initial_mode = "insert",
  })
  
  picker:find()
end

-- Standard input fallback
function M.standard_input(opts, callback)
  vim.ui.input(opts, function(input)
    if input then
      add_to_history(input)
    end
    callback(input)
  end)
end

-- File picker for selecting files to include in prompt
function M.file_picker(opts, callback)
  opts = opts or {}
  
  local files = file_discovery.get_all_files()
  
  if #files == 0 then
    vim.notify("No files found in workspace", vim.log.levels.WARN)
    return
  end
  
  local function make_entry(file)
    local displayer = entry_display.create({
      separator = " │ ",
      items = {
        { width = 30 },  -- Filename
        { width = 8 },   -- Extension
        { width = 20 },  -- Directory
        { remaining = true },  -- Full path
      },
    })
    
    return {
      value = file,
      display = function(entry)
        return displayer({
          { entry.value.filename, "TelescopeResultsIdentifier" },
          { entry.value.extension, "TelescopeResultsFunction" },
          { entry.value.directory, "TelescopeResultsComment" },
          { entry.value.relative_path, "TelescopeResultsSpecialComment" },
        })
      end,
      ordinal = file.search_text,
    }
  end
  
  local picker = pickers.new(opts, {
    prompt_title = "Select Files for Claude Code Prompt",
    finder = finders.new_table({
      results = files,
      entry_maker = make_entry,
    }),
    sorter = conf.generic_sorter(opts),
    attach_mappings = function(prompt_bufnr, map)
      local function select_file()
        local selection = action_state.get_selected_entry()
        if selection then
          actions.close(prompt_bufnr)
          callback(selection.value)
        end
      end
      
      actions.select_default:replace(select_file)
      
      return true
    end,
    initial_mode = "insert",
  })
  
  picker:find()
end

-- Multi-file picker for selecting multiple files
function M.multi_file_picker(opts, callback)
  opts = opts or {}
  
  local files = file_discovery.get_all_files()
  local selected_files = {}
  
  if #files == 0 then
    vim.notify("No files found in workspace", vim.log.levels.WARN)
    return
  end
  
  local function make_entry(file)
    local displayer = entry_display.create({
      separator = " │ ",
      items = {
        { width = 2 },   -- Selection indicator
        { width = 30 },  -- Filename
        { width = 8 },   -- Extension
        { width = 20 },  -- Directory
        { remaining = true },  -- Full path
      },
    })
    
    return {
      value = file,
      display = function(entry)
        local indicator = selected_files[entry.value.filepath] and "✓" or " "
        return displayer({
          { indicator, selected_files[entry.value.filepath] and "DiagnosticOk" or "TelescopeResultsComment" },
          { entry.value.filename, "TelescopeResultsIdentifier" },
          { entry.value.extension, "TelescopeResultsFunction" },
          { entry.value.directory, "TelescopeResultsComment" },
          { entry.value.relative_path, "TelescopeResultsSpecialComment" },
        })
      end,
      ordinal = file.search_text,
    }
  end
  
  local picker = pickers.new(opts, {
    prompt_title = "Select Multiple Files for Claude Code Prompt (Tab to select, Enter to confirm)",
    finder = finders.new_table({
      results = files,
      entry_maker = make_entry,
    }),
    sorter = conf.generic_sorter(opts),
    attach_mappings = function(prompt_bufnr, map)
      local function toggle_selection()
        local selection = action_state.get_selected_entry()
        if selection then
          local filepath = selection.value.filepath
          if selected_files[filepath] then
            selected_files[filepath] = nil
          else
            selected_files[filepath] = selection.value
          end
          
          -- Refresh the picker to update the display
          local current_picker = action_state.get_current_picker(prompt_bufnr)
          current_picker:refresh(finders.new_table({
            results = files,
            entry_maker = make_entry,
          }), opts)
        end
      end
      
      local function confirm_selection()
        actions.close(prompt_bufnr)
        
        local selected_list = {}
        for _, file in pairs(selected_files) do
          table.insert(selected_list, file)
        end
        
        callback(selected_list)
      end
      
      actions.select_default:replace(confirm_selection)
      map("i", "<Tab>", toggle_selection)
      map("n", "<Tab>", toggle_selection)
      
      return true
    end,
    initial_mode = "insert",
  })
  
  picker:find()
end

-- Generate context from selected files
function M.generate_file_context(files)
  if not files or #files == 0 then
    return ""
  end
  
  local context = "\n\n--- File Context ---\n"
  
  for _, file in ipairs(files) do
    local content = ""
    local file_handle = io.open(file.filepath, "r")
    if file_handle then
      content = file_handle:read("*all")
      file_handle:close()
    end
    
    context = context .. string.format("\n**%s**\n```%s\n%s\n```\n",
      file.relative_path,
      file.extension,
      content
    )
  end
  
  return context
end

-- Enhanced spawn with file suggestions
function M.enhanced_spawn(args, multiclaudecode_instance)
  M.enhanced_input({
    prompt = "Claude Code Enhanced Prompt (use @ for file suggestions):",
    default = "",
  }, function(input)
    if not input then
      return
    end
    
    -- Get current file path for appending
    local filepath = vim.fn.expand("%:p")
    
    -- Process the input message
    local final_message = input
    
    -- Check if user wants to include file context
    if input:find("@include:multiple") then
      M.multi_file_picker({}, function(selected_files)
        local context = M.generate_file_context(selected_files)
        local processed_message = input:gsub("@include:multiple", "") .. context
        
        -- Append current file path if not empty
        if filepath ~= "" then
          if processed_message ~= "" then
            processed_message = processed_message .. " " .. filepath
          else
            processed_message = filepath
          end
        end
        
        local spawn_args = vim.tbl_deep_extend("force", args or {}, { message = processed_message })
        multiclaudecode_instance.spawn_with_message(processed_message, spawn_args)
      end)
    elseif input:find("@include:single") then
      M.file_picker({}, function(selected_file)
        local context = M.generate_file_context({selected_file})
        local processed_message = input:gsub("@include:single", "") .. context
        
        -- Append current file path if not empty
        if filepath ~= "" then
          if processed_message ~= "" then
            processed_message = processed_message .. " " .. filepath
          else
            processed_message = filepath
          end
        end
        
        local spawn_args = vim.tbl_deep_extend("force", args or {}, { message = processed_message })
        multiclaudecode_instance.spawn_with_message(processed_message, spawn_args)
      end)
    else
      -- Standard spawn with enhanced input - append current file path
      if filepath ~= "" then
        if final_message ~= "" then
          final_message = final_message .. " " .. filepath
        else
          final_message = filepath
        end
      end
      
      local spawn_args = vim.tbl_deep_extend("force", args or {}, { message = final_message })
      multiclaudecode_instance.spawn_with_message(final_message, spawn_args)
    end
  end)
end

-- Setup function
function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})
  
  -- Initialize file discovery
  file_discovery.setup(M.config.file_discovery or {})
end

return M