local api = vim.api
local uv = vim.loop
local cmd = vim.cmd
local fn = vim.fn
local schedule = vim.schedule
local min = math.min
local max = math.max
local floor = math.floor
-- forward declarations
local nnnver, action, stdout, startdir, oppside, bufopts
local targetwin = { win = api.nvim_get_current_win(), buf = api.nvim_get_current_buf() }
local state = { explorer = {}, picker = {} }
local M = { builtin = {} }
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
	buflisted = false,
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
	if api.nvim_win_get_buf(state[mode][tab].win) ~= state[mode][tab].buf then
		api.nvim_win_set_buf(state[mode][tab].win, state[mode][tab].buf)
		return
	end

	if #api.nvim_tabpage_list_wins(0) == 1 then
		api.nvim_win_set_buf(state[mode][tab].win, api.nvim_create_buf(false, false))
	else
		api.nvim_win_hide(state[mode][tab].win)
	end

	state[mode][tab].win = nil
	-- restore last known active window
	if targetwin then api.nvim_set_current_win(targetwin.win) end
end

local function handle_files(iter)
	local files = {}
	local empty, notnnn

	if not targetwin.win then -- find window containing empty or non-nnn buffer
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

	api.nvim_set_current_win(targetwin.win or empty or notnnn)

	for file in iter do
		if action then
			files[#files + 1] = fn.fnameescape(file)
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
		schedule(function() print(stdout and stdout[1]:sub(1, -2)) end)
	else
		if api.nvim_win_is_valid(win) then
			if #api.nvim_tabpage_list_wins(0) == 1 then
				cmd("split")
			end
			api.nvim_win_hide(win)
		end

		if mode == "picker" then
			local fd, _ = io.open(pickertmp, "r")
			if fd then
				handle_files(io.lines(pickertmp))
			end
		end
	end
	-- restore last known active window
	if targetwin then api.nvim_set_current_win(targetwin.win) end
end

-- on_stdout callback for error catching
local function on_stdout(_, data, _)
	stdout = data
end

local function feedkeys(keys)
	api.nvim_feedkeys(api.nvim_replace_termcodes(keys, true, true, true), "m", true)
end

local function buffer_setup(mode, tab)
	for opt, val in pairs(bufopts) do
		api.nvim_buf_set_option(0, opt, val)
	end

	for i, mapping in ipairs(cfg.mappings) do
		api.nvim_buf_set_keymap(0, "t", mapping[1], "<C-\\><C-n><cmd>lua require('nnn').handle_mapping("..i..")<CR>", {})
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

 -- Restore buffer to previous state
local function restore_buffer(win, buf)
	api.nvim_win_call(win, function()
		cmd((api.nvim_buf_is_valid(targetwin.buf) and targetwin.buf ~= buf) and targetwin.buf.."buffer" or "enew")
	end)
end

-- Open explorer split and set local buffer options and mappings
local function open_explorer(tab, is_dir)
	local id = state.explorer[tab] and state.explorer[tab].id
	local buf = state.explorer[tab] and state.explorer[tab].buf
	local curwin = api.nvim_get_current_win()

	if not buf then
		if is_dir then
			cmd(cfg.explorer.side.." "..cfg.explorer.width.."vsplit")
		else
			cmd(cfg.explorer.side.." "..cfg.explorer.width.."vnew")
		end

		id = fn.termopen(cfg.explorer.cmd..startdir, {
			env = { TERM = term, NNN_OPTS = exploreropts, NNN_FIFO = explorertmp },
			on_exit = on_exit,
			on_stdout = on_stdout,
			stdout_buffered = true
		})

		buf = api.nvim_get_current_buf()
		buffer_setup("explorer", tab)
		read_fifo()
	else
		cmd(cfg.explorer.side.." "..cfg.explorer.width.."vsplit+"..buf.."buffer")
	end

	window_setup()
	state.explorer[tab] = { win = api.nvim_get_current_win(), buf = buf, id = id }

	if is_dir then
		restore_buffer(curwin, buf)
	end
end

-- Calculate window size and return table
local function get_win_size()
	local wincfg = { relative = "editor" }
	local style = cfg.picker.style
	local vim_height = api.nvim_get_option("lines")
	local vim_width = api.nvim_get_option("columns")

	wincfg.height = min(max(0, floor(style.height > 1 and style.height or (vim_height * style.height))), vim_height)
	wincfg.width = min(max(0, floor(style.width > 1 and style.width or (vim_width * style.width))), vim_width)

	local row = floor(style.yoffset > 1 and style.yoffset or (style.yoffset * (vim_height - wincfg.height)))
	local col = floor(style.xoffset > 1 and style.xoffset or (style.xoffset * (vim_width - wincfg.width)))

	wincfg.row = min(max(0, row), vim_height - wincfg.height) - 1
	wincfg.col = min(max(0, col), vim_width - wincfg.width)

	return wincfg
end

-- Create floating window for NnnPicker
local function create_float(is_dir)
	local new
	local buf = state.picker[1] and state.picker[1].buf
	local wincfg = get_win_size()
	wincfg.style = "minimal"
	wincfg.border = cfg.picker.style.border

	local win = api.nvim_open_win(0, true, wincfg)

	if not buf then
		buf = is_dir and api.nvim_get_current_buf() or api.nvim_create_buf(true, false)
		cmd("keepalt buffer"..buf)
		new = true
	end

	return win, buf, new
end

-- Open picker float and set local buffer options and mappings
local function open_picker(is_dir)
	local id = state.picker[1] and state.picker[1].id
	local curwin = api.nvim_get_current_win()
	local win, buf, new = create_float(is_dir)

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

	if is_dir then
		restore_buffer(curwin, buf)
	end
end

local function stat(name, type)
	local stats = uv.fs_stat(name)
	return stats and stats.type == type
end

-- Toggle explorer/picker windows, keeping buffers
function M.toggle(mode, dir, auto)
	local bufname = api.nvim_buf_get_name(0)
	local is_dir = stat(bufname, "directory")
	local tab = mode == "explorer" and cfg.explorer.tabs and api.nvim_get_current_tabpage() or 1

	if auto == "netrw" then
		if not is_dir then return end
		if state[mode][tab] and state[mode][tab].buf then
			api.nvim_buf_delete(state[mode][tab].buf, { force = true })
			state[mode][tab] = {}
		end
	elseif (auto == "setup" or auto == "tab") and (cfg.auto_open.empty and (bufname ~= "" and not is_dir) or
				vim.tbl_contains(cfg.auto_open.ft_ignore, api.nvim_buf_get_option(0, "filetype"))) then return
	end

	startdir = " "..fn.fnameescape(dir and fn.expand(dir) or is_dir and bufname or fn.getcwd()).." "
	local win = state[mode][tab] and state[mode][tab].win
	win = cfg.explorer.tabs and win or vim.tbl_contains(api.nvim_tabpage_list_wins(0), win)

	if win and api.nvim_win_is_valid(win) then
		close(mode, tab)
	elseif mode == "explorer" then
		if nnnver < 4.3 then
			print("NnnExplorer requires nnn version >= v4.3. Currently installed: "..
					((nnnver ~= 0) and ("v"..nnnver) or "none"))
			return
		end

		open_explorer(tab, is_dir)
	elseif mode == "picker" then
		open_picker(is_dir)
	end
end

-- Handle user defined mappings
function M.handle_mapping(key)
	action = cfg.mappings[key][2]
	feedkeys("i<CR>")
end

-- WinEnter callback to save target window filtering out nnn windows
function M.win_enter()
	schedule(function()
		if api.nvim_buf_get_option(api.nvim_win_get_buf(0), "filetype") ~= "nnn" then
			targetwin.win = api.nvim_get_current_win()
			targetwin.buf = api.nvim_get_current_buf()
		elseif #api.nvim_tabpage_list_wins(0) == 1 then
			targetwin.win = nil
		end
	end)
end

-- WinClosed callback for auto_close to close tabpage or quit vim
function M.win_closed()
	schedule(function()
		if api.nvim_buf_get_option(0, "filetype") ~= "nnn" then return end
		if #api.nvim_tabpage_list_wins(0) == 1 then
			feedkeys("<C-\\><C-n><cmd>q<CR>")
		end
	end)
end

-- TabClosed callback to clear tab from state
function M.tab_closed(tab)
	local buf = state.explorer[tab] and state.explorer[tab].buf
	if buf and api.nvim_buf_is_valid(buf) then
		 api.nvim_buf_delete(buf, { force = true })
	end
end

-- VimResized callback to resize picker window
function M.vim_resized()
	local win = state and state.picker and state.picker[1].win
	if win then api.nvim_win_set_config(win, get_win_size()) end
end

-- Builtin mapping functions
local function open_in(files, command)
	for _, file in ipairs(files) do
		cmd(command.." "..file)
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

	if previewname == files[1] then return end

	cmd("edit "..files[1])

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
	local dir_escaped = files[1]:match(".*/")
	local dir = dir_escaped:gsub("\\", "")
	local read = io.open(dir, "r")

	if read ~= nil then
		io.close(read)
		fn.execute("cd "..dir)
		vim.defer_fn(function() print("working directory changed to: "..dir) end, 0)
	end
end

function M.builtin.populate_cmdline(files)
	feedkeys(": "..table.concat(files, "\n"):gsub("\n", " ").."<C-b>")
end

function M.setup(setup_cfg)
	if setup_cfg then
		cfg = vim.tbl_deep_extend("force", cfg, setup_cfg)
	end

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
		cmd("silent! autocmd! FileExplorer *")

		schedule(function()
			M.toggle(cfg.replace_netrw, nil, "netrw")
			api.nvim_create_autocmd({ "BufEnter", "BufNewFile" }, { callback = function()
				require("nnn").toggle(cfg.replace_netrw, nil, "netrw")
			end})
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
		api.nvim_create_autocmd("VimLeavePre", { command = "call delete(fnameescape('"..sessionfile.."'))" })
	else
		if cfg.picker.session == "global" then
			pickersession = " -S "
		elseif cfg.picker.session == "local" then
			pickersession = " -S -s "..sessionfile.."-picker "
		api.nvim_create_autocmd("VimLeavePre", { command = "call delete(fnameescape('"..sessionfile.."-picker'))" })
		else
			pickersession = " "
		end

		if cfg.explorer.session == "global" then
			explorersession = " -S "
		elseif cfg.explorer.session == "local" then
			explorersession = " -S -s "..sessionfile.."-explorer "
		api.nvim_create_autocmd("VimLeavePre", { command = "call delete(fnameescape('"..sessionfile.."-explorer'))" })
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
		api.nvim_create_autocmd("WinClosed", { callback = function()
			require("nnn").win_closed()
		end})
	end

	if cfg.auto_open.tabpage then
		api.nvim_create_autocmd("TabNewEntered", { callback = function()
			vim.schedule(function() require("nnn").toggle(cfg.auto_open.tabpage, nil, "tab") end)
		end})
	end

	api.nvim_create_user_command("NnnPicker", function(opts)
		require("nnn").toggle("picker", opts.args)
	end, { nargs = "*" })
	api.nvim_create_user_command("NnnExplorer", function(opts)
		require("nnn").toggle("explorer", opts.args)
	end, { nargs = "*" })

	local group = api.nvim_create_augroup("nnn", { clear = true })
	api.nvim_create_autocmd("WinEnter", { group = group, callback = function()
		require("nnn").win_enter()
	end})
	api.nvim_create_autocmd("TermClose", { group = group, callback = function()
		if api.nvim_buf_get_option(0, "filetype") == "nnn" then
			api.nvim_buf_delete(0, { force = true })
		end
	end})
	api.nvim_create_autocmd("BufEnter", { group = group, callback = function()
		if api.nvim_buf_get_option(0, "filetype") == "nnn" then
			vim.cmd("startinsert")
		end
	end})
	api.nvim_create_autocmd("VimResized", { group = group, callback = function()
		if api.nvim_buf_get_option(0, "filetype") == "nnn" then
			require("nnn").vim_resized()
		end
	end})
	api.nvim_create_autocmd("TabClosed", { group = group, callback = function()
		require("nnn").tab_closed(tonumber(vim.fn.expand("<afile>")))
	end})

	api.nvim_set_hl(0, "NnnBorder", { link = "FloatBorder", default = true })
	api.nvim_set_hl(0, "NnnNormal", { link = "Normal", default = true })
	api.nvim_set_hl(0, "NnnNormalNC", { link = "Normal", default = true })
end

return M
