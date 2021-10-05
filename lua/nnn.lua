local api = vim.api
local uv = vim.loop
local cmd = vim.cmd
local fn = vim.fn
local defer = vim.defer_fn
local pickerregex = "term://.*nnn.*-p.*";
local fiforegex = "term://.*nnn.*-F1";
local regex = fiforegex
local curwin
local action
local pickertmp = fn.tempname() .. "-picker"
local fifotmp = fn.tempname() .. "-explorer"
local opts = os.getenv("NNN_OPTS"):gsub("a", "")
local cfg = {
	explorercmd = "nnn",
	pickercmd = "nnn",
	replace_netrw = false,
	filetype_exclude = {},
	default_mode = "explorer",
	explorer_width = 24,
	mappings = {},
	borderstyle = "single",
	session = nil, -- TODO
	layout = {} -- TODO also as mapping argument
}
local M = {}

local function get_buf()
 	for _, buf in pairs(api.nvim_list_bufs()) do
		local buf_name = api.nvim_buf_get_name(buf)
		if string.match(buf_name, regex) ~= nil then return buf end
	end
	return nil
end

local function get_win()
 	for _, win in pairs(api.nvim_tabpage_list_wins(api.nvim_tabpage_get_number(0))) do
		local buf_name = api.nvim_buf_get_name(api.nvim_win_get_buf(win))
		if string.match(buf_name, regex) ~= nil then return win end
	end
  return nil
end

local function filter_curwin_nnn()
	local windows = api.nvim_list_wins()
	curwin = api.nvim_tabpage_get_win(api.nvim_tabpage_get_number(0))
	regex = (regex == fiforegex) and pickerregex or fiforegex
	if get_win() == curwin then
		if #windows == 1 then
			cmd("vsplit")
		else
			curwin = windows[2]
		end
	end
	regex = (regex == pickerregex) and fiforegex or pickerregex
end

local function close()
  local win = get_win()
  if not win then return end
	if #api.nvim_list_wins() == 1 then
		api.nvim_win_set_buf(win, api.nvim_create_buf(false, false))
	else
  	api.nvim_win_close(win, true)
	end
end

local function read_fifo()
	uv.fs_open(fifotmp, "r+", 438, function(ferr, fd)
		if ferr then
			print("Error opening pipe for reading:" .. ferr)
		else
			local fpipe = uv.new_pipe(false)
			uv.pipe_open(fpipe, fd)
			uv.read_start(fpipe, function(rerr, chunk)
				if rerr then
					print("Read error:" .. rerr)
				elseif chunk then
					defer(function()
						if type(action) == "function" then
							action(chunk:sub(1, -2))
						elseif #api.nvim_list_wins() == 1 then
							local win = get_win()
							local portwidth = api.nvim_win_get_width(win)
							local width = portwidth - cfg.explorer_width
							cmd(width .. "vsplit " .. fn.fnameescape(chunk:sub(1, -2)))
							curwin = api.nvim_tabpage_get_win(0)
							api.nvim_set_current_win(win)
							-- TODO replace workaround for nnn shifting out of viewport
							cmd("vertical " .. win .. "resize " .. portwidth)
							cmd("vertical " .. win .. "resize " .. width)
							api.nvim_feedkeys(api.nvim_replace_termcodes("<C-\\><C-n><C-W>l", true, true, true), "t", true)
						else
							api.nvim_set_current_win(curwin)
							cmd("edit " .. fn.fnameescape(chunk:sub(1, -2)))
						end
						action = nil
					end, 0)
				else
					uv.fs_close(fd)
				end
			end)
		end
	end)
end

local function open_explorer()
	if get_win() then return end
	filter_curwin_nnn()
	local buf = get_buf()
	if buf == nil then
		cmd("topleft" .. cfg.explorer_width .. "vsplit term://NNN_OPTS=" .. opts .. " NNN_FIFO=" .. fifotmp .. " " .. cfg.explorercmd .. " -F1")
		cmd("setlocal nonumber norelativenumber winfixwidth winfixheight noshowmode buftype=terminal filetype=nnn")
		api.nvim_buf_set_keymap(get_buf(), "t", "<C-l>", "<C-\\><C-n><C-w>l", {})
		for i = 1, #cfg.mappings do
			api.nvim_buf_set_keymap(get_buf(), "t", cfg.mappings[i][1], "<C-\\><C-n><cmd>lua require('nnn').mapping('" .. i .. "')<CR>", {})
		end
		read_fifo()
	else
		cmd("topleft" .. cfg.explorer_width .. "vsplit+" .. buf .. "buffer")
	end
	cmd("startinsert")
end

local function create_float()
  local vim_height = api.nvim_eval("&lines")
  local vim_width = api.nvim_eval("&columns")

  local width = math.floor(vim_width * 0.8) + 5
  local height = math.floor(vim_height * 0.7) + 2
  local col = vim_width * 0.1 - 2
  local row = vim_height * 0.15 - 1
  local win = api.nvim_open_win(0, true, {
			relative = "editor",
			width = width,
			height = height,
			col = col,
			row = row,
			style = "minimal",
			border = cfg.borderstyle
    })
	if #api.nvim_list_bufs() == 1 or get_buf() == nil then
		local buf = api.nvim_create_buf(true, false)
		cmd("keepalt b" .. buf)
	end
	return win
end

local function on_exit()
	close()
	local fd = io.open(pickertmp, "r")
	if fd ~= nil then
		local retlines = {}
		local act = action
		for line in io.lines(pickertmp) do
			if action == nil then
				cmd("edit " .. fn.fnameescape(line))
			else
				table.insert(retlines, line)
			end
		end
		if action ~= nil then defer(function() act(retlines) end,0) end
	else
		print("error exiting nnn")
	end
	io.close(fd)
	action = nil
end

local function open_picker()
	filter_curwin_nnn()
	local win = create_float()
	local buf = get_buf()
	if buf == nil then
		fn.termopen(cfg.pickercmd .. " -p " .. pickertmp, { on_exit = on_exit })
		cmd("setlocal nonumber norelativenumber winfixwidth winfixheight noshowmode buftype=terminal filetype=nnn")
		api.nvim_buf_set_keymap(get_buf(), "t", "<C-l>", "<C-\\><C-n><C-w>l", {})
		for i = 1, #cfg.mappings do
			api.nvim_buf_set_keymap(get_buf(), "t", cfg.mappings[i][1], "<C-\\><C-n><cmd>lua require('nnn').mapping('" .. i .. "')<CR>", {})
		end
	else
		api.nvim_win_set_buf(win, buf)
	end
	cmd("startinsert")
end

function M.toggle(mode)
	if mode == nil then mode = cfg.default_mode end
	if mode == "explorer" then
		regex = fiforegex
		if get_win() then
			close()
		else
			open_explorer()
  	end
	elseif mode == "picker" then
		regex = pickerregex
		if get_win() then
			close()
		else
			open_picker()
		end
	end
end

function M.mapping(map)
	api.nvim_feedkeys(api.nvim_replace_termcodes("<C-\\><C-n>", true, true, true), "t", true)
	api.nvim_set_current_win(curwin)
	local mapping = cfg.mappings[tonumber(map)][2]
	if type(mapping) == "function" then
		action = mapping
	else
		cmd(mapping)
	end
	if get_win() == nil then open_explorer() end
	api.nvim_set_current_win(get_win())
	if regex == fiforegex then
		api.nvim_feedkeys(api.nvim_replace_termcodes("i<CR>", true, true, true), "t", true)
	else
		api.nvim_feedkeys(api.nvim_replace_termcodes("iq", true, true, true), "t", true)
	end
end

function M.setup(setup_cfg)
	cmd [[
		command! NnnPicker lua require("nnn").toggle("picker")
		command! NnnExplorer lua require("nnn").toggle("explorer")
		command! NnnToggle lua require("nnn").toggle()
		autocmd BufEnter * if &ft ==# "nnn" | startinsert | endif
		autocmd TermClose * if &ft ==# "nnn" | :bdelete! | endif
	]]

	if setup_cfg ~= nil then
		for k, v in pairs(setup_cfg) do
			if cfg[k] ~= nil then
				cfg[k] = v
			end
		end
	end

  local bufnr = api.nvim_get_current_buf()
  local bufname = api.nvim_buf_get_name(bufnr)
  local buftype = api.nvim_buf_get_option(bufnr, "filetype")
  local stats = uv.fs_stat(bufname)
  local is_dir = stats and stats.type == "directory"
	local lines = not is_dir and api.nvim_buf_get_lines(bufnr, 0, -1, false) or {}
  local buf_has_content = #lines > 1 or (#lines == 1 and lines[1] ~= "")

	if (cfg.replace_netrw and is_dir) or (bufname == "" and not buf_has_content)
		and not vim.tbl_contains(cfg.filetype_exclude, buftype) then
		vim.g.loaded_netrw = 1
		vim.g.loaded_netrwPlugin = 1
		api.nvim_buf_delete(0, {})
		defer(function() M.toggle("picker") end, 0)
	end
end

return M
