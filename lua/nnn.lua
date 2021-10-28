local api = vim.api
local uv = vim.loop
local cmd = vim.cmd
local fn = vim.fn
local npcall = vim.F.npcall
local schedule = vim.schedule
local min = math.min
local max = math.max
local floor = math.floor
-- forward declarations
local nnnver, action, stdout, bufmatch, startdir, pickerid, oppside
local M = {}
M.builtin = {}
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
		side = "topleft",
		session = "",
		tabs = true
	},
	picker = {
		cmd = "nnn",
		style = { width = 0.9, height = 0.8, xoffset = 0.5, yoffset = 0.5, border = "single" },
		session = "",
	},
	auto_open = {
		setup = nil,
		tabpage = nil,
		empty = false,
		ft_ignore = { "gitcommit" }
	},
	auto_close = false,
	replace_netrw = nil,
	mappings = {},
	windownav = { left = "<C-w>h", right = "<C-w>l" },
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
	if not bufmatch then return nil end
	for _, win in pairs(api.nvim_tabpage_list_wins(0)) do
		local winvar = npcall(api.nvim_win_get_var, win, "nnn")
		if winvar == bufmatch then return win end
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
			local winvar = npcall(api.nvim_win_get_var, win, "nnn")
			if not winvar then notnnn = win end
		end
		if not empty and not notnnn then -- create new win
			cmd(oppside.." "..api.nvim_get_option("columns") - cfg.explorer.width.."vsplit")
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
	if win then
		if #api.nvim_tabpage_list_wins(0) == 1 then cmd("split") end
		api.nvim_win_close(win, true)
	end
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

local function feedkeys(keys)
	api.nvim_feedkeys(api.nvim_replace_termcodes(keys, true, true, true), "t", true)
end

-- auto_close WinClosed callback to close tabpage or quit vim
function M.on_close()
	schedule(function()
		if not get_win() then return end
		if #api.nvim_list_tabpages() == 1 then
			if #api.nvim_list_wins() == 1 then
				feedkeys("<C-\\><C-n>:qa<CR>")
			end
		elseif api.nvim_tabpage_list_wins(0) then
			feedkeys("<C-\\><C-n>")
			cmd("tabclose")
		end
	end)
end

local function buffer_setup()
	api.nvim_buf_set_name(0, bufmatch)
	cmd("setlocal nonumber norelativenumber wrap winfixwidth winfixheight noshowmode buftype=terminal filetype=nnn")
	api.nvim_buf_set_keymap(0, "t", cfg.windownav.left, "<C-\\><C-n><C-w>h", {})
	api.nvim_buf_set_keymap(0, "t", cfg.windownav.right, "<C-\\><C-n><C-w>l", {})
	for i = 1, #cfg.mappings do
		api.nvim_buf_set_keymap(0, "t", cfg.mappings[i][1], "<C-\\><C-n><cmd>lua require('nnn').handle_mapping('"..i.."')<CR>", {})
	end
end

local function window_setup(float)
	api.nvim_win_set_var(0, "nnn", bufmatch)
	api.nvim_win_set_option(0, "winhighlight", "Normal:NnnNormal,NormalNC:NnnNormalNC"..(float and ",FloatBorder:NnnBorder" or ""))
	cmd("startinsert")
end

-- Open explorer split and set local buffer options and mappings
local function open_explorer()
	if get_win() then return end
	local buf = get_buf()
	if not buf then
		cmd(cfg.explorer.side.." "..cfg.explorer.width.."vnew")
		fn.termopen(cfg.explorer.cmd..startdir, {
			env = { TERM = term, NNN_OPTS = exploreropts, NNN_FIFO = explorertmp },
			on_exit = on_exit,
			on_stdout = on_stdout,
			stdout_buffered = true
		})
		buffer_setup()
		read_fifo()
	else
		cmd(cfg.explorer.side.." "..cfg.explorer.width.."vsplit+"..buf.."buffer")
	end
	window_setup()
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
	window_setup(true)
end

local function isdir(bufname)
	local stats = uv.fs_stat(bufname)
	return stats and stats.type == "directory"
end

-- Toggle explorer/picker windows, keeping buffers
function M.toggle(mode, dir, auto)
	local bufname = api.nvim_buf_get_name(0)
	local is_dir = isdir(bufname)
	if auto == "netrw" then
		if not is_dir then return end
		api.nvim_buf_delete(0, {})
	elseif (auto == "setup" or auto == "tab") then
		if (cfg.auto_open.empty and (bufname ~= "" and not is_dir) or
		vim.tbl_contains(cfg.auto_open.ft_ignore, api.nvim_buf_get_option(0, "filetype"))) then
			return
		end
		if isdir(bufname) then api.nvim_buf_delete(0, {}) end
	end
	startdir = dir and " "..vim.fn.expand(dir).." " or is_dir and " "..bufname.." " or ""
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
		feedkeys("i<CR>")
	else
		feedkeys("iq")
	end
end

-- VimResized callback to resize picker window
function M.resize()
	bufmatch = "NnnPicker"
	local win = get_win()
	if win then api.nvim_win_set_config(win, get_win_size()) end
end

-- Builtin mapping functions
local function open_in(files, command)
	for i = 1, #files do
		vim.cmd(command.." "..vim.fn.fnameescape(files[i]))
	end
end

function M.builtin.open_in_split(files) open_in(files, "split") end
function M.builtin.open_in_vsplit(files) open_in(files, "vsplit") end
function M.builtin.open_in_tab(files)
	vim.cmd("tabnew")
	open_in(files, "edit")
	feedkeys("<C-\\><C-n><C-w>h")
end

function M.builtin.open_in_preview(files)
	local previewbuf = api.nvim_get_current_buf()
	local previewname = api.nvim_buf_get_name(previewbuf)
	local file = fn.fnameescape(files[1])
	if previewname == file then return end
	cmd("edit "..fn.fnameescape(files[1]))
	if previewname ~= "" and not previewname:match(bufmatch) then
		api.nvim_buf_delete(previewbuf, {})
	end
	cmd("wincmd p")
end

function M.builtin.copy_to_clipboard(files)
	files = table.concat(files, "\n")
	vim.fn.setreg("+", files)
	vim.defer_fn(function() print(files:gsub("\n", ", ").." copied to register") end, 0)
end

function M.builtin.cd_to_path(files)
	local dir = files[1]:match(".*/")
	local read = io.open(dir, "r")
	if read ~= nil then
		io.close(read)
		vim.fn.execute("cd "..dir)
		vim.defer_fn(function() print("working directory changed to: "..dir) end, 0)
	end
end

function M.setup(setup_cfg)
	if setup_cfg then cfg = vim.tbl_deep_extend("force", cfg, setup_cfg) end
	oppside = cfg.explorer.side:match("to") and "botright" or "topleft"
	-- Replace netrw plugin if config is set
	if cfg.replace_netrw then
		if not vim.g.loaded_netrw then
			vim.g.loaded_netrw = 1
			vim.g.loaded_netrwPlugin = 1
			vim.g.loaded_netrwSettings = 1
			vim.g.loaded_netrwFileHandles = 1
			schedule(function() M.toggle(cfg.replace_netrw, nil, "netrw") end)
		end
		vim.cmd([[silent! autocmd! FileExplorer *
				autocmd BufEnter,BufNewFile * lua require('nnn').toggle(']]..cfg.replace_netrw..[[', nil, "netrw")]])
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
	if cfg.auto_open.setup then schedule(function() M.toggle(cfg.auto_open.setup, nil, "setup")end) end
	if cfg.auto_close then cmd("autocmd WinClosed * lua require('nnn').on_close()") end
	if cfg.auto_open.tabpage then
		cmd("autocmd TabNewEntered * lua vim.schedule(function()require('nnn').toggle('"..cfg.auto_open.tabpage.."',nil,'tab')end)")
	end
	cmd [[
		command! -nargs=? NnnPicker lua require("nnn").toggle("picker", <q-args>)
		command! -nargs=? NnnExplorer lua require("nnn").toggle("explorer", <q-args>)
		autocmd WinEnter * :lua require("nnn").save_win()
		autocmd TermClose * if &ft ==# "nnn" | :bdelete! | endif
		autocmd BufEnter * if &ft ==# "nnn" | startinsert | endif
		autocmd VimResized * if &ft ==# "nnn" | execute 'lua require("nnn").resize()' | endif
		highlight default link NnnBorder FloatBorder
		highlight default link NnnNormal Normal
		highlight default link NnnNormalNC Normal
	]]
end

return M
