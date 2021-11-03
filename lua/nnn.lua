local api = vim.api
local uv = vim.loop
local cmd = vim.cmd
local fn = vim.fn
local schedule = vim.schedule
local min = math.min
local max = math.max
local floor = math.floor
-- forward declarations
local nnnver, action, stdout, startdir, oppside
local targetwin = api.nvim_get_current_win()
local state = { explorer = {}, picker = {} }
local M = {}
M.builtin = {}
-- initialization
local pickertmp = fn.tempname().."-picker"
local explorertmp = fn.tempname().."-explorer"
local nnnopts = os.getenv("NNN_OPTS")
local term = os.getenv("TERM")
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

local winopts = {
	number = false,
	relativenumber = false,
	wrap = false,
	winfixwidth = true,
	winfixheight = true,
	winhighlight = "Normal:NnnNormal,NormalNC:NnnNormalNC,FloatBorder:NnnBorder",
}

local bufopts = {
	buftype = "terminal",
	filetype = "nnn",
}

-- Close nnn window(keeping buffer) and create new buffer if none left
local function close(mode, tab)
	if api.nvim_win_get_buf(state[mode][tab].win) ~= state[mode][tab].buf then
		api.nvim_win_set_buf(state[mode][tab].win, state[mode][tab].buf)
		return
	end

	if #api.nvim_tabpage_list_wins(0) == 1 then
		api.nvim_win_set_buf(state[mode][tab].win, api.nvim_create_buf(false, false))
	else
		api.nvim_win_close(state[mode][tab].win, true)
	end

	state[mode][tab].win = nil
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

			if api.nvim_buf_get_option(0, "filetype") ~= "nnn" then
				notnnn = win
			end
		end

		if not empty and not notnnn then -- create new win
			cmd(oppside..api.nvim_get_option("columns") - cfg.explorer.width.."vsplit")
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
	local mode = state.picker[1] and state.picker[1].id == id and "picker" or "explorer"
	local tab = (mode == "explorer" and cfg.explorer.tabs) and api.nvim_get_current_tabpage() or 1

	if code > 0 then
		schedule(function() print(stdout and stdout[1]:sub(1, -2)) end)
	else
		if api.nvim_win_is_valid(state[mode][tab].win) then
			if #api.nvim_tabpage_list_wins(0) == 1 then cmd("split") end
			api.nvim_win_close(state[mode][tab].win, true)
		end

		if mode == "picker" then
			local fd, err = io.open(pickertmp, "r")
			if fd then
				handle_files(io.lines(pickertmp))
			else
				print(err)
			end
		end
	end
	state[mode][tab] = {}
end

-- on_stdout callback for error catching
local function on_stdout(_, data, _)
	stdout = data
end

local function feedkeys(keys)
	api.nvim_feedkeys(api.nvim_replace_termcodes(keys, true, true, true), "m", true)
end

-- auto_close WinClosed callback to close tabpage or quit vim
function M.on_close()
	schedule(function()
		if api.nvim_buf_get_option(0, "filetype") ~= "nnn" then return end

		if #api.nvim_tabpage_list_wins(0) == 1 then
			feedkeys("<C-\\><C-n><cmd>q<CR>")
		end
	end)
end

local function buffer_setup(mode, tab)
	for opt, val in pairs(bufopts) do
		api.nvim_buf_set_option(0, opt, val)
	end

	for i, mapping in ipairs(cfg.mappings) do
		api.nvim_buf_set_keymap(0, "t", mapping[1], "<C-\\><C-n><cmd>lua require('nnn').handle_mapping('"..i.."')<CR>", {})
	end

	api.nvim_buf_set_keymap(0, "t", cfg.windownav.left, "<C-\\><C-n><C-w>h", {})
	api.nvim_buf_set_keymap(0, "t", cfg.windownav.right, "<C-\\><C-n><C-w>l", {})
	api.nvim_buf_set_name(0, "nnn"..mode..tab)
end

local function window_setup()
	for opt, val in pairs(winopts) do
		api.nvim_win_set_option(0, opt, val)
	end
	cmd("startinsert")
end

-- Open explorer split and set local buffer options and mappings
local function open_explorer(tab)
	local id = state.explorer[tab] and state.explorer[tab].id
	local buf = state.explorer[tab] and state.explorer[tab].buf

	if not buf then
		cmd(cfg.explorer.side.." "..cfg.explorer.width.."vnew")

		id = fn.termopen(cfg.explorer.cmd..startdir, {
			env = { TERM = term, NNN_OPTS = exploreropts, NNN_FIFO = explorertmp },
			on_exit = on_exit,
			on_stdout = on_stdout,
			stdout_buffered = true
		})

		buffer_setup("explorer", tab)
		read_fifo()
	else
		cmd(cfg.explorer.side.." "..cfg.explorer.width.."vsplit+"..buf.."buffer")
	end

	window_setup()
	state.explorer[tab] = { win = api.nvim_get_current_win(), buf = buf or api.nvim_get_current_buf(), id = id }
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
	local buf = state.picker[1] and state.picker[1].buf
	local wincfg = get_win_size()
	wincfg.style = "minimal"
	wincfg.border = cfg.picker.style.border

	local win = api.nvim_open_win(0, true, wincfg)

	if not buf then
		buf = api.nvim_create_buf(true, false)
		cmd("keepalt buffer"..buf)
		new = true
	end

	return win, buf, new
end

-- Open picker float and set local buffer options and mappings
local function open_picker()
	local id
	local win, buf, new = create_float()

	if new then
		id = fn.termopen(cfg.picker.cmd..startdir, {
			env = { TERM = term },
			on_exit = on_exit,
			on_stdout = on_stdout,
			stdout_buffered = true
		})

		buffer_setup("picker", 1)
	else
		api.nvim_win_set_buf(win, buf)
	end

	window_setup()
	state.picker[1] = { win = win, buf = buf, id = id }
end

local function stat(name, type)
	local stats = uv.fs_stat(name)
	return stats and stats.type == type
end

-- Toggle explorer/picker windows, keeping buffers
function M.toggle(mode, dir, auto)
	local bufname = api.nvim_buf_get_name(0)
	local is_dir = stat(bufname, "directory")

	if auto == "netrw" then
		if not is_dir then return end
		api.nvim_buf_delete(0, {})
	elseif (auto == "setup" or auto == "tab") then
		if (vim.tbl_contains(cfg.auto_open.ft_ignore, api.nvim_buf_get_option(0, "filetype")) or
				cfg.auto_open.empty and (bufname ~= "" and not is_dir)) then return end

		if is_dir then
			api.nvim_buf_delete(0, {})
		end
	end

	startdir = (" %s "):format(dir and fn.expand(dir) or is_dir and bufname or "")
	local tab = mode == "explorer" and cfg.explorer.tabs and api.nvim_get_current_tabpage() or 1
	local win = state[mode][tab] and state[mode][tab].win
	win = cfg.explorer.tabs and win or table.contains(api.nvim_tabpage_list_wins(0), win)

	if win then
		close(mode, tab)
	elseif mode == "explorer" then
		if nnnver < 4.3 then
			print("NnnExplorer requires nnn version >= v4.3. Currently installed: "..
					((nnnver ~= 0) and ("v"..nnnver) or "none"))
			return
		end

		open_explorer(tab)
	elseif mode == "picker" then
		open_picker()
	end
end

-- Handle user defined mappings
function M.handle_mapping(key)
	action = cfg.mappings[tonumber(key)][2]
	feedkeys("i"..(api.nvim_buf_get_name(0):match("nnnexplorer") and "<CR>" or "q"))
end

-- WinEnter callback to save target window filtering out nnn windows
function M.save_win()
	schedule(function()
		if api.nvim_buf_get_option(api.nvim_win_get_buf(0), "filetype") ~= "nnn" then
			targetwin = api.nvim_get_current_win()
		elseif #api.nvim_tabpage_list_wins(0) == 1 then
			targetwin = nil
		end
	end)
end

-- VimResized callback to resize picker window
function M.resize()
	local win = state and state.picker and state.picker.win
	if win then api.nvim_win_set_config(win, get_win_size()) end
end

-- BufDelete callback to clear mode from state
function M.clear_state(bufname)
	state[bufname:match("explorer") and "explorer" or "picker"] = nil
end

-- Builtin mapping functions
local function open_in(files, command)
	for _, file in ipairs(files) do
		print(file)
		cmd(command.." "..fn.fnameescape(file))
	end
end

function M.builtin.open_in_split(files) open_in(files, "split") end
function M.builtin.open_in_vsplit(files) open_in(files, "vsplit") end
function M.builtin.open_in_tab(files)
	cmd("tabnew")
	open_in(files, "edit")
	feedkeys("<C-\\><C-n><C-w>h")
end

function M.builtin.open_in_preview(files)
	local previewbuf = api.nvim_get_current_buf()
	local previewname = api.nvim_buf_get_name(previewbuf)
	local file = fn.fnameescape(files[1])

	if previewname == file then return end

	cmd("edit "..fn.fnameescape(files[1]))

	if previewname ~= "" then
		api.nvim_buf_delete(previewbuf, {})
	end

	cmd("wincmd p")
end

function M.builtin.copy_to_clipboard(files)
	files = table.concat(files, "\n")
	fn.setreg("+", files)
	vim.defer_fn(function() print(files:gsub("\n", ", ").." copied to register") end, 0)
end

function M.builtin.cd_to_path(files)
	local dir = files[1]:match(".*/")
	local read = io.open(dir, "r")

	if read ~= nil then
		io.close(read)
		fn.execute("cd "..dir)
		vim.defer_fn(function() print("working directory changed to: "..dir) end, 0)
	end
end

function M.setup(setup_cfg)
	if setup_cfg then
		cfg = vim.tbl_deep_extend("force", cfg, setup_cfg)
	end

	-- Replace netrw plugin if config is set
	if cfg.replace_netrw then
		if not vim.g.loaded_netrw then
			vim.g.loaded_netrw = 1
			vim.g.loaded_netrwPlugin = 1
			vim.g.loaded_netrwSettings = 1
			vim.g.loaded_netrwFileHandles = 1
		end

		schedule(function()
			M.toggle(cfg.replace_netrw, nil, "netrw")

			if api.nvim_buf_get_option(0, "filetype") == "netrw" then
				api.nvim_buf_delete(0, {})
			end

			cmd([[silent! autocmd! FileExplorer *
				autocmd BufEnter,BufNewFile * lua require('nnn').toggle(']]..cfg.replace_netrw..[[', nil, "netrw")]])
		end)
	end

	-- Version check for explorer mode
	local verfd = io.popen("nnn -V")
	nnnver = tonumber(verfd:read()) or 0
	verfd:close()

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
		if cfg.picker.session == "global" then
			pickersession = " -S "
		elseif cfg.picker.session == "local" then
			pickersession = " -S -s "..sessionfile.."-picker "
			cmd("autocmd VimLeavePre * call delete(fnameescape('"..sessionfile.."-picker'))")
		else
			pickersession = " "
		end

		if cfg.explorer.session == "global" then
			explorersession = " -S "
		elseif cfg.explorer.session == "local" then
			explorersession = " -S -s "..sessionfile.."-explorer "
			cmd("autocmd VimLeavePre * call delete(fnameescape('"..sessionfile.."-explorer'))")
		else
			explorersession = " "
		end
	end

	if not stat(explorertmp, "fifo") then 
		os.execute("mkfifo "..explorertmp)
	end

	oppside = cfg.explorer.side:match("to") and "botright " or "topleft "
	cfg.picker.cmd = cfg.picker.cmd.." -p "..pickertmp..pickersession
	cfg.explorer.cmd = cfg.explorer.cmd.." -F1 "..explorersession

	if cfg.auto_open.setup and not (cfg.replace_netrw and stat(api.nvim_buf_get_name(0), "directory")) then
		schedule(function() M.toggle(cfg.auto_open.setup, nil, "setup") end)
	end

	if cfg.auto_close then
		cmd("autocmd WinClosed * lua require('nnn').on_close()")
	end

	if cfg.auto_open.tabpage then
		cmd("autocmd TabNewEntered * lua vim.schedule(function()require('nnn').toggle('"..cfg.auto_open.tabpage.."',nil,'tab')end)")
	end

	cmd [[
		command! -nargs=? NnnPicker lua require("nnn").toggle("picker", <q-args>)
		command! -nargs=? NnnExplorer lua require("nnn").toggle("explorer", <q-args>)
		autocmd WinEnter * :lua require("nnn").save_win()
		autocmd TermClose * if &ft ==# "nnn" | :bdelete! | endif
		autocmd BufEnter * if &ft ==# "nnn" | startinsert | endif
		autocmd BufDelete * if &ft ==# "nnn" | lua require('nnn').clear_state(<abuf>) | endif
		autocmd VimResized * if &ft ==# "nnn" | execute 'lua require("nnn").resize()' | endif
		highlight default link NnnBorder FloatBorder
		highlight default link NnnNormal Normal
		highlight default link NnnNormalNC Normal
	]]
end

return M
