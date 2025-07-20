# multiclaudecode.nvim

A Neovim plugin to spawn and manage multiple Claude Code CLI sessions with notification support.

## Features

- Spawn multiple Claude Code sessions in interactive terminals
- Floating terminal windows by default (hide with `<Esc>` or `q`)
- Full terminal interaction - type and respond to Claude Code directly
- **Custom input with @ file mentions** - Type `@filename` to include file contents
- Enhanced prompt with Telescope file suggestions (optional)
- Manage sessions with commands and UI
- Get notifications when sessions complete using Claude Code hooks
- Toggle session visibility (show/hide terminals)
- Kill running sessions
- Telescope integration with terminal content preview
- Lualine status component showing active sessions
- Live session status updates and previews

## Installation

Using [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "qtnx/multiclaudecode.nvim",
  dependencies = {
    "nvim-telescope/telescope.nvim",  -- Optional but recommended
  },
  config = function()
    require("multiclaudecode").setup({
      -- Configuration options
      notify_on_complete = true,
      claude_code_path = "claude",
      notification_port = 9999,
      default_args = {},
      skip_permissions = true,  -- Add --dangerously-skip-permissions by default
      model = "sonnet",  -- Default model: "opus" or "sonnet"
      terminal = {
        split_direction = "float",  -- "float", "botright", "topleft", "vertical"
        split_size = 0.4,  -- 40% of screen (for non-float windows)
        start_insert = true,  -- Auto enter insert mode
        close_on_exit = false,  -- Keep terminal open after exit
        show_only_first_time = false,  -- Only show terminal for first spawn in new repository
        float_opts = {
          relative = "editor",
          width = 0.8,  -- 80% of editor width
          height = 0.8,  -- 80% of editor height
          border = "rounded",  -- Border style
        },
      },
    })
  end,
}
```

## Usage

### Commands

- `:ClaudeCodeSpawn [args]` - Spawn a new Claude Code session in an interactive terminal
- `:ClaudeCodeCustomInput [args]` - Spawn with custom input supporting @ file mentions
- `:ClaudeCodeEnhancedSpawn [args]` - Spawn with Telescope file suggestions
- `:ClaudeCodeSpawnSelection` - Spawn with visual selection as context
- `:ClaudeCodeSpawnLine` - Spawn with current line as context
- `:ClaudeCodeList` - List all sessions and select one to attach to
- `:ClaudeCodeKill [session_id]` - Kill a running session (shows picker if no ID provided)
- `:ClaudeCodeTranscript [session_id]` - View the transcript file for a session (shows picker if no ID provided)
- `:ClaudeCodeToggle [session_id]` - Toggle visibility of a session terminal (show/hide)
- `:ClaudeCodeAttachRecent` - Attach to most recent session
- `:ClaudeCodeTelescope` - Open Telescope session manager (recommended)

### Telescope Integration

If you have telescope.nvim installed, you can use the advanced session manager:

```vim
" Open Telescope session manager
:Telescope multiclaudecode sessions

" Or use the command
:ClaudeCodeTelescope
```

#### Telescope Keybindings

In the Telescope picker:
- `<CR>` - Attach to selected session (opens terminal)
- `<C-k>` or `k` - Kill selected session
- `<C-t>` or `t` - View transcript
- `<C-n>` or `n` - Spawn new session
- `<C-r>` or `r` - Refresh session list
- `<C-v>` or `v` - Toggle session visibility
- `<Esc>` or `q` - Close

The Telescope integration provides:
- Live status updates (auto-refreshes every 2 seconds for running sessions)
- Session duration tracking
- Detailed previews with recent output
- Quick actions without confirmation prompts

### Background Session Mode

When `show_only_first_time` is set to `true`, the plugin will only show the terminal window for the first session spawned in each repository. Subsequent sessions in the same repository will run in the background without showing the terminal window.

This is useful for workflows where you want to:
- Keep the editor uncluttered after the first session
- Spawn multiple sessions without window interruption
- Access sessions only when needed via `:ClaudeCodeList` or Telescope

```lua
terminal = {
  show_only_first_time = true,  -- Only show terminal for first spawn per repository
}
```

When sessions are spawned in background mode, you'll see a notification with the session ID and can access them via:
- `:ClaudeCodeList` - List all sessions and attach to any
- `:ClaudeCodeTelescope` - Telescope interface with session management
- `:ClaudeCodeToggle` - Toggle visibility of the most recent session

### Examples

```vim
" Spawn a new Claude Code session (opens in floating window)
:ClaudeCodeSpawn

" Spawn with specific arguments
:ClaudeCodeSpawn --model claude-3-opus-20240229

" Select some code and spawn with it as context
:'<,'>ClaudeCodeSpawnSelection

" Spawn with current line
:ClaudeCodeSpawnLine

" List and attach to a session
:ClaudeCodeList

" Toggle session visibility
:ClaudeCodeToggle

" Kill a specific session
:ClaudeCodeKill 1234567890_5678
```

### Custom Input with @ File Mentions

The custom input feature provides a non-Telescope alternative for including files in your prompts:

1. **Using Custom Input**: Run `:ClaudeCodeCustomInput` or press `<leader>cc`
2. **File Mentions**: Type `@` followed by a filename to trigger file completion
3. **Navigation**: 
   - `Tab` - Navigate through file suggestions or trigger completion
   - `Shift-Tab` - Navigate backwards through suggestions
   - `Enter` - Accept the selected file or submit the prompt
   - `Up/Down` - Navigate through prompt history
   - `Escape` - Cancel input

**Example workflow:**
```
Claude Code prompt: Can you help me refactor @main.lua to be more modular?
```

When you submit, the plugin will:
- Find and read the content of `main.lua`
- Include it in the prompt with proper formatting
- Automatically append the current file path
- Send everything to Claude Code

**Features:**
- Real-time file completion as you type after `@`
- Shows relative file paths for easy identification
- Searches through all project files (respecting .gitignore patterns)
- Maintains prompt history across sessions
- Multiple file mentions supported in a single prompt

### Using with Code Selection

1. **Visual Selection**: Select code in visual mode, then press `<leader>ce` (or use `:ClaudeCodeSpawnSelection`)
2. **Current Line**: Press `<leader>ce` in normal mode to send the current line
3. **Quick Toggle**: Press `<leader>ct` to show/hide the most recent session

When using code selection or current line:
- You'll be prompted for your question/request first
- The plugin automatically adds the full file path and line numbers
- Your prompt is sent first, followed by the code context
- Example output:
  ```
  Your prompt here...
  
  File: /home/user/project/src/main.py
  Lines: 15-20
  
  ```python
  def calculate_total(items):
      return sum(item.price for item in items)
  ```
  ```

### Terminal Keybindings

In the Claude Code terminal windows:
- `<Esc>` - Hide the floating window (works in both normal and terminal mode)
- `q` - Hide the floating window (normal mode only)
- `i` - Enter insert mode to interact with Claude
- `<C-\><C-n>` - Exit terminal mode to normal mode

## Lualine Integration

Add the Claude Code status to your lualine configuration:

```lua
require('lualine').setup {
  sections = {
    lualine_x = {
      -- Other components...
      require('multiclaudecode.lualine').get_component(),
    },
  },
}
```

The status component shows:
- 🤖 - Active running sessions with duration
- ✓ - Completed sessions count
- Latest notification message
- Click to open Telescope session manager

You can also use the simple status function:
```lua
lualine_x = {
  { require('multiclaudecode.lualine').status },
}
```

## Configuration

```lua
require("multiclaudecode").setup({
  -- Show notifications when sessions complete
  notify_on_complete = true,
  
  -- Path to Claude Code CLI executable
  claude_code_path = "claude",
  
  -- Directory to store hook scripts
  hooks_dir = vim.fn.stdpath("data") .. "/multiclaudecode/hooks",
  
  -- Port for notification server
  notification_port = 9999,
  
  -- Default arguments for all sessions
  default_args = {
    -- Add any default Claude Code arguments here
  },
  
  -- Add --dangerously-skip-permissions flag by default (set to false to disable)
  skip_permissions = true,
  
  -- Default model to use ("opus" or "sonnet")
  model = "sonnet",
  
  -- Terminal window configuration
  terminal = {
    split_direction = "float",  -- "float", "botright", "topleft", "vertical"
    split_size = 0.4,  -- 40% of screen (for non-float windows)
    start_insert = true,  -- Auto enter insert mode
    close_on_exit = false,  -- Keep terminal open after exit
    float_opts = {
      relative = "editor",
      width = 0.8,  -- 80% of editor width
      height = 0.8,  -- 80% of editor height
      border = "rounded",  -- Border style
    },
  },
  
  -- Keymaps (set to false to disable)
  keymaps = {
    spawn = "<leader>cs",          -- Spawn new session with prompt
    spawn_with_selection = "<leader>ce", -- Spawn with visual selection/current line
    spawn_no_prompt = "<leader>cn", -- Spawn new session without prompt
    toggle = "<leader>ct",         -- Toggle session visibility
    kill = "<leader>ck",           -- Kill session
    list = "<leader>cl",           -- List sessions (telescope)
    attach = "<leader>ca",         -- Attach to last session
    enhanced_spawn = "<leader>cS", -- Enhanced spawn with Telescope file suggestions
    custom_input_spawn = "<leader>cc", -- Spawn with custom input (@ file mentions)
  },
})
```

## Default Keymaps

| Keymap | Mode | Description |
|--------|------|-------------|
| `<leader>cs` | Normal | Spawn new Claude Code session (prompts for input) |
| `<leader>cc` | Normal | Spawn with custom input (@ file mentions) |
| `<leader>cS` | Normal | Enhanced spawn with Telescope file suggestions |
| `<leader>ce` | Visual | Spawn with selected text + prompt |
| `<leader>ce` | Normal | Spawn with current line + prompt |
| `<leader>cn` | Normal | Spawn without prompt |
| `<leader>ct` | Normal | Toggle recent session visibility |
| `<leader>ck` | Normal | Kill recent running session |
| `<leader>cl` | Normal | List all sessions (Telescope) |
| `<leader>ca` | Normal | Attach to most recent session |

All spawn commands will prompt you for input. When using `<leader>ce` with selection or on a line, your prompt will be sent first, followed by the code context with full file path and line numbers.

To disable a keymap, set it to `false`:
```lua
keymaps = {
  spawn = false,  -- Disable this keymap
  toggle = "<C-c>t",  -- Or use a different key
}
```

## How it works

1. Each Claude Code session runs in its own Neovim terminal buffer
2. You can interact with Claude Code directly in the terminal
3. The plugin creates hook scripts for both PostToolUse and Notification events
4. Updates `~/.claude/settings.json` to add hooks for the session
5. Starts a lightweight HTTP server to receive notifications
6. Claude Code sends notifications through the Notification hook with messages like "Task completed successfully"
7. You get real-time notifications in Neovim as Claude Code works
8. Sessions can be hidden/shown, allowing you to work with multiple Claude instances
9. When the session completes or is killed, all hooks are automatically removed from settings.json

## Notification Structure

When Claude Code sends a notification, it includes:
- `session_id`: The unique session identifier
- `transcript_path`: Path to the conversation transcript file
- `hook_event_name`: "Notification" or "PostToolUse"
- `message`: The notification message (e.g., "Task completed successfully")

## API

```lua
local multiclaudecode = require("multiclaudecode")

-- Spawn a new session programmatically
local session_id = multiclaudecode.spawn({ model = "claude-3-opus-20240229" })

-- Spawn with initial message
multiclaudecode.spawn_with_message("Can you help me refactor this function?", {})

-- Spawn with visual selection
multiclaudecode.spawn_with_selection()

-- Spawn with current line
multiclaudecode.spawn_with_current_line()

-- List all sessions
local sessions = multiclaudecode.list_sessions()

-- Get session stats
local stats = multiclaudecode.get_stats()
-- Returns: { total = 3, running = 1, completed = 2, active_session = {...} }

-- Attach to a specific session (opens terminal)
multiclaudecode.attach_to_session(session_id)

-- Attach to most recent session
multiclaudecode.attach_to_recent()

-- Toggle session visibility
multiclaudecode.toggle_session(session_id)

-- Send text to a session
multiclaudecode.send_to_session(session_id, "Hello Claude!\n")

-- Kill a session
multiclaudecode.kill_session(session_id)
```

## License

MIT