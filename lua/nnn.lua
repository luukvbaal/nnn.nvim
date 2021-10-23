local api = vim.api
local uv = vim.loop
local cmd = vim.cmd
local fn = vim.fn
local schedule = vim.schedule
local min = math.min
local max = math.max
local floor = math.floor
-- forward declarations
local nnnver, action, stdout, bufmatch, startdir, pickerid
local M = {}
-- initialization
local pickertmp = fn.tempname().."-picker"
local explorertmp = fn.tempname().."-explorer"
local nnnopts = os.getenv("NNN_OPTS")
local term = os.getenv("TERM")
local targetwin = api.nvim_get_current_win()
local exploreropts = nnnopts and nnnopts:gsub("a", "") or ""

local cfg = {
	explorer = {
		cmd = "nnn",
		width = 24,
		session = "",
		tabs = true
	},
	picker = {
		cmd = "nnn",
		style = { width = 0.9, height = 0.8, xoffset = 0.5, yoffset = 0.5, border = "single" },
		session = "",
	},
	replace_netrw = nil,
	mappings = {},
	windownav = "<C-w>l",
}

-- Return buffer matching global bufmatch<tab>
local function get_buf()
	for _, buf in pairs(api.nvim_list_bufs()) do
		if api.nvim_buf_get_name(buf):match(bufmatch) then return buf end
	end
	return nil
end

-- Return window containing buffer matching global bufmatch
local function get_win()
	for _, win in pairs(api.nvim_tabpage_list_wins(0)) do
		local ok, winvar = pcall(api.nvim_win_get_var, win, "nnn")
		if ok and winvar == bufmatch then return win end
	end
	return nil
end

-- Save target window on WinEnter filtering out nnn windows
function M.save_win()
	schedule(function()
		if api.nvim_buf_get_option(api.nvim_win_get_buf(0), "filetype") ~= "nnn" then
			targetwin = api.nvim_get_current_win()
		elseif #api.nvim_tabpage_list_wins(0) == 1 then
			targetwin = nil
		end
	end)
end

-- Close nnn window(keeping buffer) and create new buffer one if none left
local function close()
	local win = get_win()
	if not win then return end
	local buf = get_buf()
	if api.nvim_win_get_buf(win) ~= buf then
		api.nvim_win_set_buf(win, buf)
		return
	end
	if #api.nvim_tabpage_list_wins(0) == 1 then
		api.nvim_win_set_buf(win, api.nvim_create_buf(false, false))
	else
		api.nvim_win_close(win, true)
	end
end

local function handle_files(iter)
	local files = {}
	local empty, notnnn
	if not targetwin then -- find window containing empty or non-nnn buffer
		for _, win in pairs(api.nvim_tabpage_list_wins(0)) do
			if api.nvim_buf_get_name(api.nvim_win_get_buf(win)) == "" then
				empty = win
				break
			end
			local ok, _ = pcall(api.nvim_win_get_var, win, "nnn")
			if not ok then notnnn = win end
		end
		if not empty and notnnn or not targetwin then -- create new win
			cmd("botright "..api.nvim_get_option("columns") - cfg.explorer.width.."vsplit")
			targetwin = api.nvim_get_current_win()
		end
	end
	api.nvim_set_current_win(targetwin or empty or notnnn)
	for file in iter do
		if action then
			files[#files + 1] = file
		else
			cmd("edit "..fn.fnameescape(file))
		end
	end
	if action then
		schedule(function()
			action(files)
			action = nil
		end)
	end
end

-- Read fifo for explorer asynchronously with vim.loop
local function read_fifo()
	uv.fs_open(explorertmp, "r+", 438, function(ferr, fd)
		if ferr then
			schedule(function() print(ferr) end)
		else
			local fpipe = uv.new_pipe(false)
			fpipe:open(fd)
			fpipe:read_start(function(rerr, chunk)
				if not rerr and chunk then
					schedule(function()
						handle_files(chunk:gmatch("[^\n]+"))
					end)
				else
					fpipe:close()
				end
			end)
		end
	end)
end

-- on_exit callback for picker mode
local function on_exit(id, code)
	if code > 0 then
		schedule(function() print(stdout[1]:sub(1, -2)) end)
		return
	end
	local win = get_win()
	if win then api.nvim_win_close(win, true) end
	if id == pickerid then
		local fd, err = io.open(pickertmp, "r")
		if fd then
			handle_files(io.lines(pickertmp))
		else
			print(err)
		end
	end
end

-- on_stdout callback for error catching
local function on_stdout(_, data, _)
	stdout = data
end

local function buffer_setup()
	api.nvim_buf_set_name(0, bufmatch)
	cmd("setlocal nonumber norelativenumber wrap winhighlight=Normal: winfixwidth winfixheight noshowmode buftype=terminal filetype=nnn")
	api.nvim_buf_set_keymap(0, "t", cfg.windownav, "<C-\\><C-n><C-w>l", {})
	for i = 1, #cfg.mappings do
		api.nvim_buf_set_keymap(0, "t", cfg.mappings[i][1], "<C-\\><C-n><cmd>lua require('nnn').handle_mapping('"..i.."')<CR>", {})
	end
end

-- Open explorer split and set local buffer options and mappings
local function open_explorer()
	if get_win() then return end
	local buf = get_buf()
	if not buf then
		cmd("topleft"..cfg.explorer.width.."vnew")
		fn.termopen(cfg.explorer.cmd..startdir, {
			env = { TERM = term, NNN_OPTS = exploreropts, NNN_FIFO = explorertmp },
			on_exit = on_exit,
			on_stdout = on_stdout,
			stdout_buffered = true
		})
		buffer_setup()
		read_fifo()
	else
		cmd("topleft"..cfg.explorer.width.."vsplit+"..buf.."buffer")
	end
	api.nvim_win_set_var(0, "nnn", bufmatch)
	cmd("startinsert")
end

-- Calculate window size and return table
local function get_win_size()
	local wincfg = { relative = "editor" }
	local vim_height = api.nvim_get_option("lines")
	local vim_width = api.nvim_get_option("columns")
	wincfg.height = min(max(0, floor(vim_height * cfg.picker.style.height)), vim_height)
	wincfg.width = min(max(0, floor(vim_width * cfg.picker.style.width)), vim_width)
	local row = floor(cfg.picker.style.yoffset * (vim_height - wincfg.height))
	local col = floor(cfg.picker.style.xoffset * (vim_width - wincfg.width))
	wincfg.row = min(max(0, row), vim_height - wincfg.height) - 1
	wincfg.col = min(max(0, col), vim_width - wincfg.width)
	return wincfg
end

-- Create floating window for NnnPicker
local function create_float()
	local new
	local buf = get_buf()
	local wincfg = get_win_size()
	wincfg.style = "minimal"
	wincfg.border = cfg.picker.style.border
	local win = api.nvim_open_win(0, true, wincfg)
	if not get_buf() then
		buf = api.nvim_create_buf(true, false)
		cmd("keepalt buffer"..buf)
		new = true
	end
	return win, buf, new
end

-- Open picker float and set local buffer options and mappings
local function open_picker()
	local win, buf, new = create_float()
	if new then
		pickerid = fn.termopen(cfg.picker.cmd..startdir, {
			env = { TERM = term },
			on_exit = on_exit,
			on_stdout = on_stdout,
			stdout_buffered = true
		})
		buffer_setup()
	else
		api.nvim_win_set_buf(win, buf)
	end
	api.nvim_win_set_var(0, "nnn", bufmatch)
	cmd("startinsert")
end

-- Toggle explorer/picker windows, keeping buffers
function M.toggle(mode, dir, netrw)
	local bufname, isdir
	if netrw then
		bufname = api.nvim_buf_get_name(api.nvim_get_current_buf())
		local stats = uv.fs_stat(bufname)
		isdir = stats and stats.type == "directory"
		if not isdir then return end
		api.nvim_buf_delete(0, {})
	end
	startdir = dir and " "..vim.fn.expand(dir).." " or isdir and " "..bufname.." " or ""
	if mode == "explorer" then
		if nnnver < 4.3 then
			print("NnnExplorer requires nnn version >= v4.3. Currently installed: "..
					((nnnver ~= 0) and ("v"..nnnver) or "none"))
			return
		end
		bufmatch = "NnnExplorer"..(cfg.explorer.tabs and api.nvim_get_current_tabpage() or "")
		if get_win() then
			close()
		else
			open_explorer()
		end
	elseif mode == "picker" then
		bufmatch = "NnnPicker"
		if get_win() then
			close()
		else
			open_picker()
		end
	end
end

-- Handle user defined mappings
function M.handle_mapping(key)
	action = cfg.mappings[tonumber(key)][2]
	if api.nvim_buf_get_name(0):match("NnnExplorer") then
		api.nvim_feedkeys(api.nvim_replace_termcodes("i<CR>", true, true, true), "t", true)
	else
		api.nvim_feedkeys("iq", "t", true)
	end
end

function M.resize()
	bufmatch = "NnnPicker"
	local win = get_win()
	if win then api.nvim_win_set_config(win, get_win_size()) end
end

-- Setup function
function M.setup(setup_cfg)
	if setup_cfg then cfg = vim.tbl_deep_extend("force", cfg, setup_cfg) end
	-- Replace netrw plugin if config is set
	if cfg.replace_netrw then
		if not vim.g.loaded_netrw then
			vim.g.loaded_netrw = 1
			vim.g.loaded_netrwPlugin = 1
			vim.g.loaded_netrwSettings = 1
			vim.g.loaded_netrwFileHandles = 1
			schedule(function() M.toggle(cfg.replace_netrw, nil, true) end)
		end
		vim.cmd([[silent! autocmd! FileExplorer *
							autocmd BufEnter,BufNewFile * lua require('nnn').toggle(']]..cfg.replace_netrw..[[', nil, true)]])
		if api.nvim_buf_get_option(0, "filetype") == "netrw" then api.nvim_buf_delete(0, {}) end
	end
	-- Version check for explorer mode
	local verfd = io.popen("nnn -V")
	nnnver = tonumber(verfd:read()) or 0
	verfd:close()
	os.execute("mkfifo "..explorertmp)
	-- Setup sessionfile name and remove on exit
	local pickersession, explorersession
	local sessionfile = os.getenv("XDG_CONFIG_HOME")
	sessionfile = (sessionfile and sessionfile or (os.getenv("HOME").."/.config"))..
			"/nnn/sessions/nnn.nvim-"..os.date("%Y-%m-%d_%H-%M-%S")
	if cfg.picker.session == "shared" or cfg.explorer.session == "shared" then
		pickersession = " -S -s "..sessionfile
		explorersession = pickersession
		cmd("autocmd VimLeavePre * call delete(fnameescape('"..sessionfile.."'))")
	else
		if cfg.picker.session == "global" then pickersession = " -S "
		elseif cfg.picker.session == "local" then
			pickersession = " -S -s "..sessionfile.."-picker "
			cmd("autocmd VimLeavePre * call delete(fnameescape('"..sessionfile.."-picker'))")
		else pickersession = " " end

		if cfg.explorer.session == "global" then explorersession = " -S "
		elseif cfg.explorer.session == "local" then
			explorersession = " -S -s "..sessionfile.."-explorer "
			cmd("autocmd VimLeavePre * call delete(fnameescape('"..sessionfile.."-explorer'))")
		else explorersession = " " end
	end
	cfg.picker.cmd = cfg.picker.cmd.." -p "..pickertmp..pickersession
	cfg.explorer.cmd = cfg.explorer.cmd.." -F1 "..explorersession
	-- Register toggle commands, enter insertmode in nnn buffers and delete buffers on quit
	cmd [[
		command! -nargs=? NnnPicker lua require("nnn").toggle("picker", <q-args>)
		command! -nargs=? NnnExplorer lua require("nnn").toggle("explorer", <q-args>)
		autocmd WinEnter * :lua require("nnn").save_win()
		autocmd TermClose * if &ft ==# "nnn" | :bdelete! | endif
		autocmd BufEnter * if &ft ==# "nnn" | startinsert | endif
		autocmd VimResized * if &ft ==# "nnn" | execute 'lua require("nnn").resize()' | endif
	]]
end

return M
