local api = vim.api
local uv = vim.loop
local cmd = vim.cmd
local fn = vim.fn
local schedule = vim.schedule
local min = math.min
local max = math.max
local floor = math.floor
-- forward declarations
local nnnver
local curwin
local action
local stdout
local bufmatch
local startdir
local pickersession
local explorersession
local M = {}
-- initialization
local pickertmp = fn.tempname() .. "-picker"
local explorertmp = fn.tempname() .. "-explorer"
local nnnopts = os.getenv("NNN_OPTS")
local exploreropts = nnnopts and nnnopts:gsub("a", "") or ""
local sessionfile = os.getenv("XDG_CONFIG_HOME")
sessionfile = (sessionfile and sessionfile or (os.getenv("HOME") .. ".config")) ..
		"/nnn/sessions/nnn.nvim-" .. os.date("%Y-%m-%d_%H-%M-%S")

local cfg = {
	explorer = {
		cmd = "nnn",
		width = 24,
		session = "",
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

-- Return buffer matching global bufmatch
local function get_buf()
	for _, buf in pairs(api.nvim_list_bufs()) do
		if api.nvim_buf_get_name(buf):match(bufmatch) then return buf end
	end
	return nil
end

-- Return window containing buffer matching global bufmatch
local function get_win()
	for _, win in pairs(api.nvim_tabpage_list_wins(api.nvim_tabpage_get_number(0))) do
		if api.nvim_buf_get_name(api.nvim_win_get_buf(win)):match(bufmatch) then return win end
	end
	return nil
end

-- Avoid opening in picker buffer from explorer or vice versa
local function filter_curwin_nnn()
	local windows = api.nvim_list_wins()
	curwin = api.nvim_tabpage_get_win(api.nvim_tabpage_get_number(0))
	bufmatch = (bufmatch == "NnnPicker") and "NnnExplorer" or "NnnPicker"
	if get_win() == curwin then
		if #windows == 1 then
			cmd("vsplit")
		else
			curwin = windows[2]
		end
	end
	bufmatch = (bufmatch == "NnnExplorer") and "NnnPicker" or "NnnExplorer"
end

-- Close nnn window(keeping buffer) and create new buffer one if none left
local function close()
	local win = get_win()
	if not win then return end
	if #api.nvim_list_wins() == 1 then
		api.nvim_win_set_buf(win, api.nvim_create_buf(false, false))
	else
		api.nvim_win_close(win, true)
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
						if type(action) == "function" then
							action({ chunk:sub(1, -2) })
						elseif #api.nvim_list_wins() == 1 then
							cmd("botright vsplit " .. fn.fnameescape(chunk:sub(1, -2)))
							curwin = api.nvim_tabpage_get_win(0)
							api.nvim_set_current_win(get_win())
							cmd("vertical resize" .. 1) -- workaround for nnn shifting out of viewport
							cmd("vertical resize" .. cfg.explorer.width)
							api.nvim_feedkeys(api.nvim_replace_termcodes("<C-\\><C-n><C-W>l", true, true, true), "t", true)
						else
							api.nvim_set_current_win(curwin)
							cmd("edit " .. fn.fnameescape(chunk:sub(1, -2)))
						end
						action = nil
					end)
				else
					fpipe:close()
				end
			end)
		end
	end)
end

-- on_exit callback for picker mode
local function on_exit(_, code)
	if code > 0 then
		schedule(function() print(stdout[1]:sub(1, -2)) end)
		return
	end
	close()
	local fd, err = io.open(pickertmp, "r")
	if fd then
		local retlines = {}
		local act = action
		for line in io.lines(pickertmp) do
			if not action then
				cmd("edit " .. fn.fnameescape(line))
			else
				table.insert(retlines, line)
			end
		end
		if action then schedule(function() act(retlines) end) end
	else
		print(err)
	end
	action = nil
end

-- on_stdout callback for error catching
local function on_stdout(_, data, _)
	stdout = data
end

-- Open explorer split and set local buffer options and mappings
local function open_explorer()
	if get_win() then return end
	filter_curwin_nnn()
	local buf = get_buf()
	if not buf then
		api.nvim_create_buf(true, false)
		cmd("topleft" .. cfg.explorer.width .. "vnew")
		fn.termopen(cfg.explorer.cmd .. " -F1 -p " .. pickertmp .. explorersession .. startdir, { env = { NNN_OPTS = exploreropts, NNN_FIFO = explorertmp }, on_exit = on_exit, on_stdout = on_stdout, stdout_buffered = true })
		api.nvim_buf_set_name(0, bufmatch)
		cmd("setlocal nonumber norelativenumber winhighlight=Normal: winfixwidth winfixheight noshowmode buftype=terminal filetype=nnn")
		api.nvim_buf_set_keymap(0, "t", cfg.windownav, "<C-\\><C-n><C-w>l", {})
		for i = 1, #cfg.mappings do
			api.nvim_buf_set_keymap(0, "t", cfg.mappings[i][1], "<C-\\><C-n><cmd>lua require('nnn').handle_mapping('" .. i .. "')<CR>", {})
		end
		schedule(function() read_fifo() end)
	else
		cmd("topleft" .. cfg.explorer.width .. "vsplit+" .. buf .. "buffer")
	end
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
	local wincfg = get_win_size()
	wincfg.style = "minimal"
	wincfg.border = cfg.picker.style.border
	local win = api.nvim_open_win(0, true, wincfg)
	if not get_buf() then
		local buf = api.nvim_create_buf(true, false)
		cmd("keepalt buffer" .. buf)
	end
	return win
end

-- Open picker float and set local buffer options and mappings
local function open_picker()
	filter_curwin_nnn()
	local win = create_float()
	local buf = get_buf()
	if not buf then
		fn.termopen(cfg.picker.cmd .. " -p " .. pickertmp .. pickersession .. startdir, { on_exit = on_exit, on_stdout = on_stdout, stdout_buffered = true })
		api.nvim_buf_set_name(0, bufmatch)
		cmd("setlocal nonumber norelativenumber winhighlight=Normal: winfixwidth winfixheight noshowmode buftype=terminal filetype=nnn")
		api.nvim_buf_set_keymap(0, "t", cfg.windownav, "<C-\\><C-n><C-w>l", {})
		for i = 1, #cfg.mappings do
			api.nvim_buf_set_keymap(0, "t", cfg.mappings[i][1], "<C-\\><C-n><cmd>lua require('nnn').handle_mapping('" .. i .. "')<CR>", {})
		end
	else
		api.nvim_win_set_buf(win, buf)
	end
	cmd("startinsert")
end

-- Toggle explorer/picker windows, keeping buffers
function M.toggle(mode, dir)
	startdir = dir and " " .. vim.fn.expand(dir) .. " " or ""
	if mode == "explorer" then
		if nnnver < 4.3 then print("NnnExplorer requires nnn version >= v4.3. Currently installed: " .. ((nnnver ~= 0) and ("v" .. nnnver) or "none")) return end
		bufmatch = "NnnExplorer"
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
function M.handle_mapping(map)
	local quit = false
	local mapping = cfg.mappings[tonumber(map)][2]
	api.nvim_feedkeys(api.nvim_replace_termcodes("<C-\\><C-n>", true, true, true), "t", true)
	if type(mapping) == "function" then
		action = mapping
	elseif type(mapping) == "table" then
		action = mapping[1]
		quit = mapping.quit
	else
		if mapping:match("tab") then
			cmd(mapping)
			open_explorer()
		else
			api.nvim_set_current_win(curwin)
			cmd(mapping)
		end
	end
	api.nvim_set_current_win(get_win())
	if api.nvim_buf_get_name(0):match("NnnExplorer") then
		api.nvim_feedkeys(quit and "iq" or api.nvim_replace_termcodes("i<CR>", true, true, true), "t", true)
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
	if setup_cfg then
		local function merge(t1, t2)
				for k, v in pairs(t2) do
						if (type(v) == "table") and (type(t1[k] or false) == "table") then
								merge(t1[k], t2[k])
						else
								t1[k] = v
						end
				end
				return t1
		end
		merge(cfg, setup_cfg)
	end
	-- Version check for explorer mode
	local verfd = io.popen("nnn -V")
	nnnver = tonumber(verfd:read()) or 0
	verfd:close()
	-- Replace netrw plugin if config is set
	if cfg.replace_netrw == "explorer" or cfg.replace_netrw == "picker" then
		local bufnr = api.nvim_get_current_buf()
		local bufname = api.nvim_buf_get_name(bufnr)
		local stats = uv.fs_stat(bufname)
		local is_dir = stats and stats.type == "directory"
		local lines = not is_dir and api.nvim_buf_get_lines(bufnr, 0, -1, false) or {}
		local buf_has_content = #lines > 1 or (#lines == 1 and lines[1] ~= "")
		if is_dir or (bufname == "" and not buf_has_content) then
			vim.g.loaded_netrw = 1
			vim.g.loaded_netrwPlugin = 1
			vim.g.loaded_netrwSettings = 1
			vim.g.loaded_netrwFileHandlers = 1
			api.nvim_buf_delete(0, {})
			schedule(function() M.toggle(cfg.replace_netrw, is_dir and bufname) end)
		end
	end
	-- Setup sessionfile name and remove on exit
	if cfg.picker.session == "shared" or cfg.explorer.session == "shared" then
		pickersession = " -S -s " .. sessionfile
		explorersession = pickersession
		cmd("autocmd VimLeavePre * call delete(fnameescape('".. sessionfile .."'))")
	else
		if cfg.picker.session == "global" then pickersession = " -S "
		elseif cfg.picker.session == "local" then
			pickersession = " -S -s " .. sessionfile .. "-picker "
			cmd("autocmd VimLeavePre * call delete(fnameescape('".. sessionfile .. "-picker'))")
		else pickersession = " " end

		if cfg.explorer.session == "global" then explorersession = " -S "
		elseif cfg.explorer.session == "local" then
			explorersession = " -S -s " .. sessionfile .. "-explorer "
			cmd("autocmd VimLeavePre * call delete(fnameescape('".. sessionfile .. "-explorer'))")
		else explorersession = " " end
	end
	-- Register toggle commands, enter insertmode in nnn buffers and delete buffers on quit
	cmd [[
		command! -nargs=? NnnPicker lua require("nnn").toggle("picker", <q-args>)
		command! -nargs=? NnnExplorer lua require("nnn").toggle("explorer", <q-args>)
		autocmd VimResized * if &ft ==# "nnn" | execute 'lua require("nnn").resize()' | endif
		autocmd BufEnter * if &ft ==# "nnn" | startinsert | endif
		autocmd TermClose * if &ft ==# "nnn" | :bdelete! | endif
	]]
end

return M
