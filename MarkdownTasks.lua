-- MarkdownTasks.lua
-- A Neovim plugin for managing Markdown tasks in a split view

local api = vim.api
local fn = vim.fn

local M = {}

-- Configuration options with defaults
M.config = {
  width = 40,            -- Width of the task split
  top_height = 10,       -- Height of incomplete tasks section (in lines)
  update_interval = 1000, -- Update interval in ms
  git_integration = false, -- Whether to commit changes to git before adding a timestamped note
}

-- State variables
M.state = {
  source_buf = nil,      -- Buffer ID of the markdown file
  incomplete_buf = nil,  -- Buffer ID of incomplete tasks view
  complete_buf = nil,    -- Buffer ID of complete tasks view
  is_active = false,     -- Whether the task split is open
  incomplete_win = nil,  -- Window ID of incomplete tasks view
  complete_win = nil,    -- Window ID of complete tasks view
  task_split_win = nil,  -- Window ID of the task split
  incomplete_tasks = {}, -- Store task data structure for incomplete tasks
  complete_tasks = {},   -- Store task data structure for complete tasks
}

-- Parse markdown content for tasks
local function parse_tasks(content)
  local incomplete_tasks = {}
  local complete_tasks = {}
  
  for i, line in ipairs(content) do
    -- Check if line contains a task marker
    local task_content = line:match("%-%s%[%s?%]%s*(.*)")
    if task_content then
      -- Remove any indentation
      local clean_line = line:gsub("^%s*", "")
      table.insert(incomplete_tasks, {
        line_number = i,
        content = clean_line,
      })
    end
    
    -- Check if line contains a completed task marker
    local completed_task_content = line:match("%-%s%[X%]%s*(.*)")
    if completed_task_content then
      -- Remove any indentation
      local clean_line = line:gsub("^%s*", "")
      table.insert(complete_tasks, {
        line_number = i,
        content = clean_line,
      })
    end
  end
  
  return incomplete_tasks, complete_tasks
end

-- Update task views with fresh content
local function update_task_views()
  if not M.state.is_active then
    return
  end
  
  local content = api.nvim_buf_get_lines(M.state.source_buf, 0, -1, false)
  local incomplete_tasks, complete_tasks = parse_tasks(content)
  
  -- Store the task data in state
  M.state.incomplete_tasks = incomplete_tasks
  M.state.complete_tasks = complete_tasks
  
  -- Update incomplete tasks buffer
  api.nvim_buf_set_option(M.state.incomplete_buf, 'modifiable', true)
  local incomplete_lines = {}
  for _, task in ipairs(incomplete_tasks) do
    -- Don't add the comment with line number
    table.insert(incomplete_lines, task.content)
  end
  api.nvim_buf_set_lines(M.state.incomplete_buf, 0, -1, false, incomplete_lines)
  api.nvim_buf_set_option(M.state.incomplete_buf, 'modifiable', false)
  
  -- Update complete tasks buffer
  api.nvim_buf_set_option(M.state.complete_buf, 'modifiable', true)
  local complete_lines = {}
  for _, task in ipairs(complete_tasks) do
    -- Don't add the comment with line number
    table.insert(complete_lines, task.content)
  end
  api.nvim_buf_set_lines(M.state.complete_buf, 0, -1, false, complete_lines)
  api.nvim_buf_set_option(M.state.complete_buf, 'modifiable', false)
end

-- Toggle task status (incomplete <-> complete)
local function toggle_task_status()
  -- Get current buffer and line
  local current_buf = api.nvim_get_current_buf()
  local line_number
  
  -- Get the line number from state data if in task views
  if current_buf == M.state.incomplete_buf then
    -- Get cursor position in incomplete tasks view
    local cursor_pos = api.nvim_win_get_cursor(0)[1]
    -- Get the corresponding task data
    if cursor_pos <= #M.state.incomplete_tasks then
      line_number = M.state.incomplete_tasks[cursor_pos].line_number
    else
      return
    end
  elseif current_buf == M.state.complete_buf then
    -- Get cursor position in complete tasks view
    local cursor_pos = api.nvim_win_get_cursor(0)[1]
    -- Get the corresponding task data
    if cursor_pos <= #M.state.complete_tasks then
      line_number = M.state.complete_tasks[cursor_pos].line_number
    else
      return
    end
  else
    -- If in source buffer, get cursor position
    line_number = api.nvim_win_get_cursor(0)[1]
  end
  
  -- Get the line content from the source buffer
  local line = api.nvim_buf_get_lines(M.state.source_buf, line_number - 1, line_number, false)[1]
  
  -- Check if it's a task line
  if not line:match("%-%s%[.?%]") then
    return
  end
  
  -- Toggle the task status
  local new_line
  if line:match("%-%s%[X%]") then
    new_line = line:gsub("%-%s%[X%]", "- [ ]")
  else
    new_line = line:gsub("%-%s%[%s?%]", "- [X]")
  end
  
  -- Update the line in the source buffer
  api.nvim_buf_set_lines(M.state.source_buf, line_number - 1, line_number, false, {new_line})
  
  -- Update task views
  update_task_views()
end

-- Check if file is in a git repository and is tracked
local function is_git_tracked(file_path)
  -- Check if git command is available
  local has_git = fn.executable('git') == 1
  if not has_git then
    return false
  end
  
  -- Check if file is in a git repository
  local is_in_git_repo = fn.system('git -C ' .. fn.shellescape(fn.fnamemodify(file_path, ':h')) .. ' rev-parse --is-inside-work-tree 2>/dev/null')
  if vim.v.shell_error ~= 0 then
    return false
  end
  
  -- Check if file is tracked by git
  local is_tracked = fn.system('git -C ' .. fn.shellescape(fn.fnamemodify(file_path, ':h')) .. ' ls-files --error-unmatch ' .. fn.shellescape(file_path) .. ' 2>/dev/null')
  if vim.v.shell_error ~= 0 then
    return false
  end
  
  return true
end

-- Commit current file to git
local function git_commit_file(file_path, commit_message)
  -- Save all changes
  vim.cmd('silent! wall')
  
  -- Stage the file
  local stage_cmd = 'git -C ' .. fn.shellescape(fn.fnamemodify(file_path, ':h')) .. ' add ' .. fn.shellescape(file_path)
  fn.system(stage_cmd)
  
  if vim.v.shell_error ~= 0 then
    print("MarkdownTasks: Failed to stage file for commit")
    return false
  end
  
  -- Commit the file
  local commit_cmd = 'git -C ' .. fn.shellescape(fn.fnamemodify(file_path, ':h')) .. ' commit -m ' .. fn.shellescape(commit_message)
  fn.system(commit_cmd)
  
  if vim.v.shell_error ~= 0 then
    print("MarkdownTasks: Failed to commit file")
    return false
  end
  
  return true
end

-- Jump from task view to source view
function M.jump_to_source()
  -- Get current buffer and cursor position
  local current_buf = api.nvim_get_current_buf()
  local cursor_pos = api.nvim_win_get_cursor(0)[1]
  local line_number
  
  -- Check if we're in one of the task views
  if current_buf == M.state.incomplete_buf then
    -- Get line number from the task data
    if cursor_pos <= #M.state.incomplete_tasks then
      line_number = M.state.incomplete_tasks[cursor_pos].line_number
    else
      return
    end
  elseif current_buf == M.state.complete_buf then
    -- Get line number from the task data
    if cursor_pos <= #M.state.complete_tasks then
      line_number = M.state.complete_tasks[cursor_pos].line_number
    else
      return
    end
  else
    return
  end
  
  -- Switch to source window and set cursor position
  for _, win in pairs(api.nvim_list_wins()) do
    if api.nvim_win_get_buf(win) == M.state.source_buf then
      api.nvim_set_current_win(win)
      api.nvim_win_set_cursor(win, {line_number, 0})
      return
    end
  end
end

-- Create a timestamped note heading
function M.create_timestamped_note()
  -- Ensure we're in the source buffer
  local current_buf = api.nvim_get_current_buf()
  local source_win
  
  if current_buf ~= M.state.source_buf then
    -- Find and switch to source window
    for _, win in pairs(api.nvim_list_wins()) do
      if api.nvim_win_get_buf(win) == M.state.source_buf then
        api.nvim_set_current_win(win)
        source_win = win
        break
      end
    end
    
    if not source_win then
      return
    end
  else
    source_win = api.nvim_get_current_win()
  end
  
  -- Create timestamp
  local timestamp = os.date("%Y-%m-%d %H:%M:%S")
  
  -- Git integration
  if M.config.git_integration then
    -- Get the file path
    local file_path = api.nvim_buf_get_name(M.state.source_buf)
    
    -- Check if file is tracked by git
    if is_git_tracked(file_path) then
      -- Save the file before committing
      vim.cmd('silent! write')
      
      -- Commit to git with timestamp as message
      local success = git_commit_file(file_path, timestamp)
      
      if success then
        print("MarkdownTasks: Committed changes to git with timestamp: " .. timestamp)
      end
    end
  end
  
  -- Find the first level-1 heading
  local content = api.nvim_buf_get_lines(M.state.source_buf, 0, -1, false)
  local first_heading_line = -1
  
  for i, line in ipairs(content) do
    if line:match("^#%s+.*%s*$") then
      first_heading_line = i
      break
    end
  end
  
  if first_heading_line == -1 then
    -- No heading found, add one at the top
    api.nvim_buf_set_lines(M.state.source_buf, 0, 0, false, {"# Untitled", "", "## " .. timestamp, "", ""})
    api.nvim_win_set_cursor(source_win, {6, 0})  -- Position cursor one line lower
  else
    -- Add timestamped note right after the first heading
    api.nvim_buf_set_lines(M.state.source_buf, first_heading_line, first_heading_line, false, {"", "## " .. timestamp, "", ""})
    api.nvim_win_set_cursor(source_win, {first_heading_line + 4, 0})  -- Position cursor one line lower
  end
  
  -- Enter insert mode
  vim.cmd("startinsert")
  
  -- Update task views
  update_task_views()
end

-- Create task view buffers
local function create_task_buffers()
  -- Create buffer for incomplete tasks
  M.state.incomplete_buf = api.nvim_create_buf(false, true)
  api.nvim_buf_set_name(M.state.incomplete_buf, "Incomplete Tasks")
  api.nvim_buf_set_option(M.state.incomplete_buf, 'filetype', 'markdown')
  api.nvim_buf_set_option(M.state.incomplete_buf, 'modifiable', false)
  
  -- Create buffer for complete tasks
  M.state.complete_buf = api.nvim_create_buf(false, true)
  api.nvim_buf_set_name(M.state.complete_buf, "Complete Tasks")
  api.nvim_buf_set_option(M.state.complete_buf, 'filetype', 'markdown')
  api.nvim_buf_set_option(M.state.complete_buf, 'modifiable', false)
  
  -- Set up key mappings for both buffers
  local buffers = {M.state.incomplete_buf, M.state.complete_buf}
  for _, buf in ipairs(buffers) do
    -- Toggle task status with <C-Space>
    api.nvim_buf_set_keymap(buf, 'n', '<C-Space>', 
      ':lua require("MarkdownTasks").toggle_task()<CR>', 
      {noremap = true, silent = true})
      
    -- Jump to source with 'gt'
    api.nvim_buf_set_keymap(buf, 'n', 'gt',
      ':lua require("MarkdownTasks").jump_to_source()<CR>',
      {noremap = true, silent = true})
  end
end

-- Set up word wrapping with proper indentation
local function setup_word_wrapping(buf)
  -- Enable line wrapping
  api.nvim_buf_set_option(buf, 'wrap', true)
  
  -- Enable line break on word boundary
  api.nvim_buf_set_option(buf, 'linebreak', true)
  
  -- Set breakindent to maintain indentation on wrapped lines
  api.nvim_buf_set_option(buf, 'breakindent', true)
  
  -- Set breakindentopt to add 2 more spaces for wrapped lines
  api.nvim_buf_set_option(buf, 'breakindentopt', 'shift:2')
  
  -- Use showbreak to indicate wrapped lines
  api.nvim_buf_set_option(buf, 'showbreak', '')
end

-- Open the task split
function M.open_task_split()
  -- Store the current buffer as the source
  M.state.source_buf = api.nvim_get_current_buf()
  
  -- Check if the current buffer is a markdown file
  local filetype = api.nvim_buf_get_option(M.state.source_buf, 'filetype')
  if filetype ~= 'markdown' then
    print("MarkdownTasks: Current buffer is not a markdown file")
    return
  end
  
  -- Create the task buffers if they don't exist
  if not M.state.incomplete_buf or not M.state.complete_buf then
    create_task_buffers()
  end
  
  -- Save the current window as source window
  local source_win = api.nvim_get_current_win()
  
  -- Setup word wrapping for source buffer
  setup_word_wrapping(M.state.source_buf)
  
  -- Create vertical split to the right for tasks view
  vim.cmd('botright vsplit')
  M.state.task_split_win = api.nvim_get_current_win()
  api.nvim_win_set_width(M.state.task_split_win, M.config.width)
  
  -- Create horizontal split for incomplete/complete tasks
  vim.cmd('split')
  M.state.incomplete_win = api.nvim_get_current_win()
  api.nvim_win_set_buf(M.state.incomplete_win, M.state.incomplete_buf)
  
  -- Setup word wrapping for incomplete tasks buffer
  setup_word_wrapping(M.state.incomplete_buf)
  
  -- Use the numerical height directly
  local height = M.config.top_height
  if type(height) ~= "number" then
    -- If for some reason it's still a string, try to convert it
    if type(height) == "string" and height:match("%%$") then
      -- Convert from percentage to lines
      local percentage = tonumber(height:match("(%d+)")) or 50
      local total_height = api.nvim_win_get_height(M.state.task_split_win)
      height = math.floor(total_height * percentage / 100)
    else
      -- Default to 10 lines if conversion fails
      height = 10
    end
  end
  
  -- Set the height with the numerical value
  api.nvim_win_set_height(M.state.incomplete_win, height)
  
  -- Set the bottom window for complete tasks
  vim.cmd('wincmd j')
  M.state.complete_win = api.nvim_get_current_win()
  api.nvim_win_set_buf(M.state.complete_win, M.state.complete_buf)
  
  -- Setup word wrapping for complete tasks buffer
  setup_word_wrapping(M.state.complete_buf)
  
  -- Go back to the source window
  api.nvim_set_current_win(source_win)
  
  -- Set up key mappings for the source buffer
  api.nvim_buf_set_keymap(M.state.source_buf, 'n', '<C-Space>', 
    ':lua require("MarkdownTasks").toggle_task()<CR>', 
    {noremap = true, silent = true})
    
  -- Set up key mapping for timestamped notes
  api.nvim_buf_set_keymap(M.state.source_buf, 'n', '<C-n>',
    ':lua require("MarkdownTasks").create_timestamped_note()<CR>',
    {noremap = true, silent = true})
  
  -- Update status and views
  M.state.is_active = true
  update_task_views()

  -- Set the statusline to appear globally at the bottom instead of per-split.
  vim.cmd('set laststatus=3')
  
  -- Set up auto-updating with a timer
  local timer = vim.loop.new_timer()
  timer:start(0, M.config.update_interval, vim.schedule_wrap(function()
    if M.state.is_active then
      update_task_views()
    else
      timer:stop()
    end
  end))
end

-- Close the task split
function M.close_task_split()
  if M.state.task_split_win and api.nvim_win_is_valid(M.state.task_split_win) then
    api.nvim_win_close(M.state.task_split_win, true)
  end
  
  if M.state.incomplete_win and api.nvim_win_is_valid(M.state.incomplete_win) then
    api.nvim_win_close(M.state.incomplete_win, true)
  end
  
  if M.state.complete_win and api.nvim_win_is_valid(M.state.complete_win) then
    api.nvim_win_close(M.state.complete_win, true)
  end
  
  M.state.is_active = false
end

-- Toggle the task split (open if closed, close if open)
function M.toggle_task_split()
  if M.state.is_active then
    M.close_task_split()
  else
    M.open_task_split()
  end
end

-- Toggle task status (exported function)
function M.toggle_task()
  toggle_task_status()
end

-- Setup function for configuration
function M.setup(opts)
  -- Merge user config with defaults
  if opts then
    for k, v in pairs(opts) do
      M.config[k] = v
    end
  end
  
  -- Create user commands
  vim.cmd([[
    command! MarkdownTasksOpen lua require('MarkdownTasks').open_task_split()
    command! MarkdownTasksClose lua require('MarkdownTasks').close_task_split()
    command! MarkdownTasksToggle lua require('MarkdownTasks').toggle_task_split()
  ]])
  
  -- Create auto commands for markdown files
  vim.cmd([[
    augroup MarkdownTasks
      autocmd!
      autocmd FileType markdown nnoremap <buffer> <C-Space> :lua require('MarkdownTasks').toggle_task()<CR>
      autocmd FileType markdown nnoremap <buffer> <C-n> :lua require('MarkdownTasks').create_timestamped_note()<CR>
    augroup END
  ]])
end

return M
