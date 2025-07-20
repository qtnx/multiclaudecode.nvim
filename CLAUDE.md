# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

This is a Neovim plugin that provides integration with Claude Code CLI. The plugin allows users to spawn and manage multiple Claude Code sessions within Neovim, with real-time notifications and a Telescope UI.

## Development Commands

Currently, there are no formal build, test, or lint commands in this repository. The plugin is a pure Lua implementation that runs directly in Neovim without compilation.

To test changes:
1. Open Neovim with the plugin loaded
2. Run `:source %` on modified Lua files
3. Test commands like `:ClaudeCodeSpawn`, `:ClaudeCodeList`, etc.

## Architecture

### Core Components

1. **Session Management** (`lua/multiclaudecode/init.lua`)
   - Tracks all active Claude Code sessions in `M.sessions` table
   - Each session has: session_id, bufnr, job_id, terminal window, and hook paths
   - Sessions run in Neovim terminal buffers with unique IDs

2. **Notification System** (`lua/multiclaudecode/notifications.lua`)
   - Runs an HTTP server (default port 9999) to receive Claude Code notifications
   - Creates bash hook scripts that Claude Code executes via its hooks system
   - Updates `~/.claude/settings.json` to register PostToolUse and Notification hooks
   - Hooks send HTTP POST requests to the notification server

3. **Terminal Management**
   - Default: floating windows (80% of editor size)
   - Alternative: split windows (configurable direction and size)
   - Windows can be hidden/shown without killing the session
   - Keybindings: `<Esc>` or `q` to hide, `i` to interact

4. **Telescope Integration** (`lua/multiclaudecode/telescope.lua`)
   - Live status updates with 2-second refresh for running sessions
   - Preview shows terminal buffer content with session details
   - Actions: attach, kill, view transcript, toggle visibility, spawn new

5. **Custom Input System** (`lua/multiclaudecode/custom_input.lua`)
   - Non-Telescope input with @ file mention support
   - Real-time file completion as you type after @
   - Maintains prompt history across sessions
   - Processes @ mentions to include file contents in prompts

6. **File Discovery** (`lua/multiclaudecode/file_discovery.lua`)
   - Scans workspace for files, respecting .gitignore patterns
   - Caches file information for fast searching
   - Provides file search and completion functionality

### Key Functions

- `spawn()`: Creates new Claude Code session with terminal and hooks
- `spawn_with_custom_input()`: Spawns session with custom input supporting @ file mentions
- `enhanced_spawn()`: Spawns session with Telescope file suggestions
- `attach_to_session()`: Opens/focuses a session's terminal window
- `toggle_session()`: Show/hide session window
- `kill_session()`: Terminates session and cleans up hooks
- `update_claude_settings()`: Manages hooks in ~/.claude/settings.json

### Plugin Entry Points

- `plugin/multiclaudecode.lua`: Auto-loaded by Neovim, prevents double-loading
- `lua/telescope/_extensions/multiclaudecode.lua`: Registers Telescope extension

## Important Implementation Details

1. **Hook Management**: The plugin modifies `~/.claude/settings.json` to add/remove hooks. It preserves existing settings and only modifies the hooks array.

2. **Session IDs**: Format is `{timestamp}_{random}` to ensure uniqueness.

3. **Terminal Buffers**: Each Claude Code instance runs in a dedicated terminal buffer that persists even when the window is hidden.

4. **Notification Flow**: Claude Code → Hook Script → HTTP POST → Notification Server → Neovim notify

5. **Cleanup**: When sessions end or are killed, hooks are automatically removed from settings.json.