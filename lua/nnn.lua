local a = vim.api
local o = vim.o
local u = vim.loop
local c = vim.cmd
local f = vim.fn
local S = vim.schedule
local min = math.min
local max = math.max
local floor = math.floor
-- forward declarations
local action, stdout, startdir, oppside, bufopts
local targetwin = { win = a.nvim_get_current_win(), buf = a.nvim_get_current_buf() }
local state = { explorer = {}, picker = {} }
local M = { builtin = {} }
-- initialization
local pickertmp = f.tempname().."-picker"
local explorertmp = f.tempname().."-explorer"
local nnnopts = os.getenv("NNN_OPTS")
local nnntmpfile = os.getenv("NNN_TMPFILE") or
		(os.getenv("XDG_CONFIG_HOME") or os.getenv("HOME").."/.config").."/nnn/.lastd"
local tmpdir = os.getenv("TMPDIR") or "/tmp"
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
	windownav = { left = "<C-w>h", right = "<C-w>l", next = "<C-w>w", prev = "<C-w>W" },
	buflisted = false,
	quitcd = nil,
	offset = false,
}

local winopts = {
	number = false,
	relativenumber = false,
	wrap = false,
	winfixwidth = true,
	winfixheight = true,
	winhighlight = "Normal:NnnNormal,NormalNC:NnnNormalNC,FloatBorder:NnnBorder",
}

-- Close nnn window(keeping buffer) and create new buffer if none left
local function close(mode, tab)
	if a.nvim_win_get_buf(state[mode][tab].win) ~= state[mode][tab].buf then
		a.nvim_win_set_buf(state[mode][tab].win, state[mode][tab].buf)
		return
	end

	if #a.nvim_tabpage_list_wins(0) == 1 then
		a.nvim_win_set_buf(state[mode][tab].win, a.nvim_create_buf(false, false))
	else
		a.nvim_win_hide(state[mode][tab].win)
	end

	state[mode][tab].win = nil
	-- restore last known active window
	if targetwin.win then a.nvim_set_current_win(targetwin.win) end
end

local function handle_files(iter, mode, tab)
	local files = {}
	local empty, notnnn
	local _, targetwintab = pcall(a.nvim_win_get_tabpage, targetwin.win)

	 -- find window containing empty or non-nnn buffer
	if not targetwin.win or targetwintab ~= a.nvim_get_current_tabpage() then
		targetwin.win = nil
		for _, win in pairs(a.nvim_tabpage_list_wins(0)) do
			if a.nvim_buf_get_name(a.nvim_win_get_buf(win)) == "" then
				empty = win
				break
			end

			if a.nvim_buf_get_option(0, "filetype") ~= "nnn" then
				notnnn = win
			end
		end

		if not empty and not notnnn then -- create new win
			c(oppside.. o.columns - cfg.explorer.width - 1 .."vsplit")
			targetwin.win = a.nvim_get_current_win()
		end
	end

	a.nvim_set_current_win(targetwin.win or empty or notnnn)

	for file in iter do
		if action then
			files[#files + 1] = f.fnameescape(file)
		else
			pcall(c, "edit "..f.fnameescape(file))
		end
	end

	if mode == "explorer" and state[mode][tab].fs then
		a.nvim_win_close(state[mode][tab].win, { force = true })
		M.toggle("explorer", false, false)
		c("vert resize +1 | vert resize -1 | wincmd p")
	end

	if action then
		S(function()
			action(files)
			action = nil
		end)
	end
end

-- Read fifo for explorer asynchronously with vim.loop
local function read_fifo()
	local tab = cfg.explorer.tabs and a.nvim_get_current_tabpage()
	u.fs_open(explorertmp, "r+", 438, function(ferr, fd)
		if ferr then
			S(function() print(ferr) end)
		else
			local fpipe = u.new_pipe(false)
			fpipe:open(fd)
			fpipe:read_start(function(rerr, chunk)
				if not rerr and chunk then
					S(function()
						handle_files(chunk:gmatch("[^\n]+"), "explorer", tab)
					end)
				else
					fpipe:close()
				end
			end)
		end
	end)
end

local function stat(name, type)
  local stats = u.fs_stat(name)
  return stats and stats.type == type
end

-- on_exit callback for termopen
local function on_exit(id, code)
	local tabpage, win
	local mode = state.picker[1] and state.picker[1].id == id and "picker" or "explorer"

	if mode == "picker" then
		tabpage = 1
		win = state.picker[1].win
	else
		for tab, nstate in pairs(state.explorer) do
			if nstate.id == id then
				tabpage = tab
				win = nstate.win
				break
			end
		end
	end
	if not tabpage then return end
	state[mode][tabpage] = {}

	if code > 0 then
		S(function() print(stdout and stdout[1]:sub(1, -2)) end)
	else
		if cfg.quitcd then
			local fd, _ = io.open(nnntmpfile, "r")
			if fd then
				c(cfg.quitcd..f.fnameescape(fd:read():sub(5, -2)))
				fd:close()
				os.remove(nnntmpfile)
			end
		end

		if a.nvim_win_is_valid(win) then
			if #a.nvim_tabpage_list_wins(0) == 1 then
				c("split")
			end
			a.nvim_win_hide(win)
			-- Delete empty buffer, not sure what creates it.
			local bufs = a.nvim_list_bufs()
			if a.nvim_buf_get_name(bufs[#bufs]) == "" then
				a.nvim_buf_delete(bufs[#bufs], {})
			end
		end

		if mode == "picker" and stat(pickertmp, "file") then
			handle_files(io.lines(pickertmp), "picker", 1)
		end
	end
	-- restore last known active window
	if targetwin then a.nvim_set_current_win(targetwin.win) end
end

-- on_stdout callback for error catching
local function on_stdout(_, data, _)
	stdout = data
end

local function feedkeys(keys)
	a.nvim_feedkeys(a.nvim_replace_termcodes(keys, true, true, true), "n", true)
end

local function buffer_setup()
	for opt, val in pairs(bufopts) do
		a.nvim_buf_set_option(0, opt, val)
	end

	for i, mapping in ipairs(cfg.mappings) do
		a.nvim_buf_set_keymap(0, "t", mapping[1], "<C-\\><C-n><cmd>lua require('nnn').handle_mapping("..i..")<CR>", {})
	end

	a.nvim_buf_set_keymap(0, "t", cfg.windownav.left, "<C-\\><C-n><C-w>h", {})
	a.nvim_buf_set_keymap(0, "t", cfg.windownav.right, "<C-\\><C-n><C-w>l", {})
	a.nvim_buf_set_keymap(0, "t", cfg.windownav.next, "<C-\\><C-n><C-w>w", {})
	a.nvim_buf_set_keymap(0, "t", cfg.windownav.prev, "<C-\\><C-n><C-w>W", {})
end

 -- Restore buffer to previous state
local function restore_buffer(win, buf)
	a.nvim_win_call(win, function()
		c((a.nvim_buf_is_valid(targetwin.buf) and targetwin.buf ~= buf) and targetwin.buf.."buffer" or "enew")
	end)
end

-- Calculate window size and return table
local function get_win_size(fullscreen)
	local lines = o.lines
	local columns = o.columns
	local wincfg = { relative = "editor", style = "minimal", height = lines, width = columns, row = 0, col = 0 }
	local style = cfg.picker.style

	if not fullscreen then
		wincfg.height = min(max(0, floor(style.height > 1 and style.height or (lines * style.height))), lines) - 1
		wincfg.width = min(max(0, floor(style.width > 1 and style.width or (columns * style.width))), columns) - 1

		local row = floor(style.yoffset > 1 and style.yoffset or (style.yoffset * (lines - wincfg.height))) - 1
		local col = floor(style.xoffset > 1 and style.xoffset or (style.xoffset * (columns - wincfg.width))) - 1

		wincfg.row = min(max(0, row), lines - wincfg.height)
		wincfg.col = min(max(0, col), columns - wincfg.width)
		wincfg.border = cfg.picker.style.border
	end

	if cfg.offset then
		local file = io.open(tmpdir.."/nnn-preview-tui-posoffset", "w")
		if file then
			file:write((wincfg.col + 1).." "..(wincfg.row + 1).."\n")
			file:close()
		end
	end

	return wincfg
end

-- Create window and return window/buffer id
local function create_win(mode, tab, is_dir, fullscreen)
	local buf = state[mode][tab] and state[mode][tab].buf
	local new = not buf
	local win, wincfg

	if mode == "picker" or fullscreen then
		if new then
			buf = is_dir and a.nvim_get_current_buf() or a.nvim_create_buf(true, false)
		end
		wincfg = get_win_size(fullscreen)
		win = a.nvim_open_win(buf, true, wincfg)
	else
		if new then
			c(cfg.explorer.side.." "..cfg.explorer.width..(is_dir and "vsplit" or "vnew"))
			buf = a.nvim_get_current_buf()
		else
			c(cfg.explorer.side.." "..cfg.explorer.width.."vsplit")
		end
		win = a.nvim_get_current_win()
	end

	return win, buf, new
end

-- Open nnn in terminal window and set window/buffer options.
local function open(mode, tab, is_dir, empty)
	local id = state[mode][tab] and state[mode][tab].id
	local curwin = a.nvim_get_current_win()
	local fs = #a.nvim_tabpage_list_wins(0) == 1 and empty
	local win, buf, new = create_win(mode, tab, is_dir, fs)

	if new then
		id = f.termopen("echo '\x1b[?1002h' && " .. cfg[mode].cmd..startdir, {
			env = (mode == "picker" and nil or
				{ NNN_OPTS = exploreropts, NNN_FIFO = explorertmp }),
			on_exit = on_exit,
			on_stdout = on_stdout,
			stdout_buffered = true
		})

		buffer_setup()
		if mode == "explorer" then read_fifo() end
	else
		a.nvim_win_set_buf(win, buf)
	end

	for opt, val in pairs(winopts) do
		a.nvim_win_set_option(0, opt, val)
	end

	state[mode][tab] = { win = win, buf = buf, id = id, fs = fs }
	c("startinsert")

	if is_dir then
		restore_buffer(curwin, buf)
	end
end

-- Toggle explorer/picker windows, keeping buffers
function M.toggle(mode, dir, auto)
	local bufname = a.nvim_buf_get_name(0)
	local is_dir = stat(bufname, "directory")
	local empty = (is_dir and f.bufname("#") or bufname) == ""
	local tab = mode == "explorer" and cfg.explorer.tabs and a.nvim_get_current_tabpage() or 1

	if auto == "netrw" then
		if not is_dir then return end
		if state[mode][tab] and state[mode][tab].buf then
			a.nvim_buf_delete(state[mode][tab].buf, { force = true })
			state[mode][tab] = {}
		end
	elseif (auto == "setup" or auto == "tab") and (cfg.auto_open.empty and (not empty and not is_dir) or
			vim.tbl_contains(cfg.auto_open.ft_ignore, a.nvim_buf_get_option(0, "filetype"))) then return
	end

	startdir = " "..f.fnameescape(dir and f.expand(dir) or is_dir and bufname or f.getcwd()).." "
	local win = state[mode][tab] and state[mode][tab].win
	win = cfg.explorer.tabs and win or vim.tbl_contains(a.nvim_tabpage_list_wins(0), win)

	if win and a.nvim_win_is_valid(win) then
		close(mode, tab)
	else
		open(mode, tab, is_dir, empty)
	end
end

-- Handle user defined mappings
function M.handle_mapping(key)
	action = cfg.mappings[key][2]
	feedkeys("i<CR>")
end

-- WinEnter callback to save target window filtering out nnn windows
function M.win_enter()
	S(function()
		if a.nvim_buf_get_option(a.nvim_win_get_buf(0), "filetype") ~= "nnn" then
			targetwin.win = a.nvim_get_current_win()
			targetwin.buf = a.nvim_get_current_buf()
		elseif #a.nvim_tabpage_list_wins(0) == 1 then
			targetwin.win = nil
		end
	end)
end

-- WinClosed callback for auto_close to close tabpage or quit vim
function M.win_closed()
	if a.nvim_win_get_config(0).zindex then return end
	S(function()
		if a.nvim_buf_get_option(0, "filetype") ~= "nnn" then return end
		local wins = 0
		-- Count non-floating windows
		for _, win in ipairs(a.nvim_tabpage_list_wins(0)) do
			if not a.nvim_win_get_config(win).zindex then
				wins = wins + 1
			end
		end
		-- Close if last non-floating window
		if wins == 1 then feedkeys("<C-\\><C-n><cmd>q<CR>") end
	end)
end

-- TabClosed callback to clear tab from state
function M.tab_closed(tab)
	local buf = state.explorer[tab] and state.explorer[tab].buf
	if buf and a.nvim_buf_is_valid(buf) then
		 a.nvim_buf_delete(buf, { force = true })
	end
end

-- VimResized callback to resize picker window
function M.vim_resized()
	local win = state and state.picker and state.picker[1].win
	if win then a.nvim_win_set_config(win, get_win_size()) end
end

-- Builtin mapping functions
local function open_in(files, command)
	for _, file in ipairs(files) do
		c(command.." "..file)
	end
end

function M.builtin.open_in_split(files) open_in(files, "split") end
function M.builtin.open_in_vsplit(files) open_in(files, "vsplit") end
function M.builtin.open_in_tab(files)
	c("tabnew")
	open_in(files, "edit")
	feedkeys("<C-\\><C-n><C-w>h")
end

function M.builtin.open_in_preview(files)
	local previewbuf = a.nvim_get_current_buf()
	local previewname = a.nvim_buf_get_name(previewbuf)

	if previewname == files[1] then return end
	c("edit "..files[1])
	if previewname ~= "" then a.nvim_buf_delete(previewbuf, {}) end
	c("wincmd p")
end

function M.builtin.copy_to_clipboard(files)
	files = table.concat(files, "\n")
	f.setreg("+", files)
	vim.defer_fn(function() print(files:gsub("\n", ", ").." copied to register") end, 0)
end

function M.builtin.cd_to_path(files)
	local dir = files[1]:match(".*/"):sub(0, -2)
	local read = io.open(dir:gsub("\\", ""), "r")

	if read ~= nil then
		io.close(read)
		f.execute("cd "..dir)
		vim.defer_fn(function() print("working directory changed to: "..dir) end, 0)
	end
end

function M.builtin.populate_cmdline(files)
	feedkeys(": "..table.concat(files, "\n"):gsub("\n", " ").."<C-b>")
end

function M.setup(setup_cfg)
	if setup_cfg then cfg = vim.tbl_deep_extend("force", cfg, setup_cfg) end

	bufopts = {
		buftype = "terminal",
		filetype = "nnn",
		buflisted = cfg.buflisted
	}

	-- Replace netrw plugin if config is set
	if cfg.replace_netrw then
		vim.g.loaded_netrw = 1
		vim.g.loaded_netrwPlugin = 1
		vim.g.loaded_netrwSettings = 1
		vim.g.loaded_netrwFileHandlers = 1
		pcall(a.nvim_clear_autocmds, { group = "FileExplorer" })

		S(function()
			M.toggle(cfg.replace_netrw, nil, "netrw")
			a.nvim_create_autocmd({ "BufEnter", "BufNewFile" }, { callback = function()
				require("nnn").toggle(cfg.replace_netrw, nil, "netrw")
			end})
		end)
	end

	-- Setup sessionfile name and remove on exit
	local pickersession, explorersession
	local sessionfile = os.getenv("XDG_CONFIG_HOME")
	sessionfile = (sessionfile and sessionfile or (os.getenv("HOME").."/.config"))..
			"/nnn/sessions/nnn.nvim-"..os.date("%Y-%m-%d_%H-%M-%S")

	if cfg.picker.session == "shared" or cfg.explorer.session == "shared" then
		pickersession = " -S -s "..sessionfile
		explorersession = pickersession
		a.nvim_create_autocmd("VimLeavePre", { command = "call delete(fnameescape('"..sessionfile.."'))" })
	else
		if cfg.picker.session == "global" then
			pickersession = " -S "
		elseif cfg.picker.session == "local" then
			pickersession = " -S -s "..sessionfile.."-picker "
		a.nvim_create_autocmd("VimLeavePre", { command = "call delete(fnameescape('"..sessionfile.."-picker'))" })
		else
			pickersession = " "
		end

		if cfg.explorer.session == "global" then
			explorersession = " -S "
		elseif cfg.explorer.session == "local" then
			explorersession = " -S -s "..sessionfile.."-explorer "
		a.nvim_create_autocmd("VimLeavePre", { command = "call delete(fnameescape('"..sessionfile.."-explorer'))" })
		else
			explorersession = " "
		end
	end

	if not stat(explorertmp, "fifo") then os.execute("mkfifo "..explorertmp) end

	oppside = cfg.explorer.side:match("to") and "botright " or "topleft "
	cfg.picker.cmd = cfg.picker.cmd.." -p "..pickertmp..pickersession
	cfg.explorer.cmd = cfg.explorer.cmd.." -F1 "..explorersession

	if cfg.auto_open.setup and not (cfg.replace_netrw and stat(a.nvim_buf_get_name(0), "directory")) then
		S(function() M.toggle(cfg.auto_open.setup, nil, "setup") end)
	end

	if cfg.auto_close then
		a.nvim_create_autocmd("WinClosed", { callback = function()
			require("nnn").win_closed()
		end})
	end

	if cfg.auto_open.tabpage then
		a.nvim_create_autocmd("TabNewEntered", { callback = function()
			vim.schedule(function() require("nnn").toggle(cfg.auto_open.tabpage, nil, "tab") end)
		end})
	end

	a.nvim_create_user_command("NnnPicker", function(opts)
		require("nnn").toggle("picker", opts.args)
	end, { nargs = "*" })
	a.nvim_create_user_command("NnnExplorer", function(opts)
		require("nnn").toggle("explorer", opts.args)
	end, { nargs = "*" })

	local group = a.nvim_create_augroup("nnn", { clear = true })
	a.nvim_create_autocmd("WinEnter", { group = group, callback = function()
		require("nnn").win_enter()
	end})
	a.nvim_create_autocmd("TermClose", { group = group, callback = function()
		if a.nvim_buf_get_option(0, "filetype") == "nnn" then
			a.nvim_buf_delete(0, { force = true })
		end
	end})
	a.nvim_create_autocmd("BufEnter", { group = group, callback = function()
		if a.nvim_buf_get_option(0, "filetype") == "nnn" then
			vim.cmd("startinsert")
		end
	end})
	a.nvim_create_autocmd("VimResized", { group = group, callback = function()
		if a.nvim_buf_get_option(0, "filetype") == "nnn" then
			require("nnn").vim_resized()
		end
	end})
	a.nvim_create_autocmd("TabClosed", { group = group, callback = function(args)
		require("nnn").tab_closed(tonumber(args.file))
	end})

	a.nvim_set_hl(0, "NnnBorder", { link = "FloatBorder", default = true })
	a.nvim_set_hl(0, "NnnNormal", { link = "Normal", default = true })
	a.nvim_set_hl(0, "NnnNormalNC", { link = "Normal", default = true })
end

return M
