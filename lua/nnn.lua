local api = vim.api
local uv = vim.loop
local cmd = vim.cmd
local fn = vim.fn
local defer = vim.defer_fn
local min = math.min
local max = math.max
local floor = math.floor
-- forward declarations
local curwin
local action
local bufmatch
local pickersession
local explorersession
local startdir = ""
local M = {}
-- initialization
local pickertmp = fn.tempname() .. "-picker"
local explorertmp = fn.tempname() .. "-explorer"
local nnnopts = os.getenv("NNN_OPTS")
local exploreropts = (nnnopts ~= nil) and nnnopts:gsub("a", "") or ""
local sessionfile = os.getenv("XDG_CONFIG_HOME")
sessionfile = ((sessionfile ~= nil) and sessionfile or (os.getenv("HOME") .. ".config")) ..
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
}


local function get_buf()
 	for _, buf in pairs(api.nvim_list_bufs()) do
		local buf_name = api.nvim_buf_get_name(buf)
		if buf_name:match(bufmatch) ~= nil then return buf end
	end
	return nil
end

local function get_win()
 	for _, win in pairs(api.nvim_tabpage_list_wins(api.nvim_tabpage_get_number(0))) do
		local buf_name = api.nvim_buf_get_name(api.nvim_win_get_buf(win))
		if buf_name:match(bufmatch) ~= nil then return win end
	end
	return nil
end

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
	uv.fs_open(explorertmp, "r+", 438, function(ferr, fd)
		if ferr then
			error("Error opening pipe for reading:" .. ferr .. "\n Avoid running nnn with the -a flag!")
		else
			local fpipe = uv.new_pipe(false)
			uv.pipe_open(fpipe, fd)
			uv.read_start(fpipe, function(rerr, chunk)
				if not rerr and chunk then
					defer(function()
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
					end, 0)
				else
					uv.fs_close(fd)
				end
			end)
		end
	end)
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
		if action ~= nil then defer(function() act(retlines) end, 0) end
	end
	io.close(fd)
	action = nil
end

local function open_explorer()
	if get_win() then return end
	filter_curwin_nnn()
	local buf = get_buf()
	if buf == nil then
		cmd("topleft" .. cfg.explorer.width .. "vnew")
		fn.termopen(cfg.explorer.cmd .. " -F1 -p " .. pickertmp .. explorersession .. startdir, { env = { NNN_OPTS = exploreropts, NNN_FIFO = explorertmp }, on_exit = on_exit })
		startdir = ""
		api.nvim_buf_set_name(0, bufmatch)
		cmd("setlocal nonumber norelativenumber winhighlight=Normal: winfixwidth winfixheight noshowmode buftype=terminal filetype=nnn")
		api.nvim_buf_set_keymap(0, "t", "<C-l>", "<C-\\><C-n><C-w>l", {})
		for i = 1, #cfg.mappings do
			api.nvim_buf_set_keymap(0, "t", cfg.mappings[i][1], "<C-\\><C-n><cmd>lua require('nnn').handle_mapping('" .. i .. "')<CR>", {})
		end
		read_fifo()
	else
		cmd("topleft" .. cfg.explorer.width .. "vsplit+" .. buf .. "buffer")
	end
	cmd("startinsert")
end

local function create_float()
	local vim_height = api.nvim_eval("&lines")
	local vim_width = api.nvim_eval("&columns")
	local height = min(max(0, floor(vim_height * cfg.picker.style.height)), vim_height)
	local width = min(max(0, floor(vim_width * cfg.picker.style.width)), vim_width)
	local row = floor(cfg.picker.style.yoffset * (vim_height - height))
	local col = floor(cfg.picker.style.xoffset * (vim_width - width))
	row = min(max(0, row), vim_height - height) - 1
	col = min(max(0, col), vim_width - width)

	local win = api.nvim_open_win(0, true, {
			relative = "editor",
			width = width,
			height = height,
			col = col,
			row = row,
			style = "minimal",
			border = cfg.picker.style.border
		})

	if #api.nvim_list_bufs() == 1 or get_buf() == nil then
		local buf = api.nvim_create_buf(true, false)
		cmd("keepalt buffer" .. buf)
	end
	return win
end

local function open_picker()
	filter_curwin_nnn()
	local win = create_float()
	local buf = get_buf()
	if buf == nil then
		fn.termopen(cfg.picker.cmd .. " -p " .. pickertmp .. pickersession .. " " .. startdir, { on_exit = on_exit })
		startdir = ""
		api.nvim_buf_set_name(0, bufmatch)
		cmd("setlocal nonumber norelativenumber winhighlight=Normal: winfixwidth winfixheight noshowmode buftype=terminal filetype=nnn")
		api.nvim_buf_set_keymap(0, "t", "<C-l>", "<C-\\><C-n><C-w>l", {})
		for i = 1, #cfg.mappings do
			api.nvim_buf_set_keymap(0, "t", cfg.mappings[i][1], "<C-\\><C-n><cmd>lua require('nnn').handle_mapping('" .. i .. "')<CR>", {})
		end
	else
		api.nvim_win_set_buf(win, buf)
	end
	cmd("startinsert")
end

function M.toggle(mode)
	if mode == "explorer" then
		local verfd = io.popen("nnn -V")
		local ver = verfd:read()
		io.close(verfd)
		if tonumber(ver) < 4.3 then print("NnnExplorer requires nnn version >= v4.3") return end
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

function M.setup(setup_cfg)
	if setup_cfg ~= nil then
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

	local bufnr = api.nvim_get_current_buf()
	local bufname = api.nvim_buf_get_name(bufnr)
	local stats = uv.fs_stat(bufname)
	local is_dir = stats and stats.type == "directory"
	local lines = not is_dir and api.nvim_buf_get_lines(bufnr, 0, -1, false) or {}
	local buf_has_content = #lines > 1 or (#lines == 1 and lines[1] ~= "")

	if (cfg.replace_netrw ~= nil) and is_dir or (bufname == "" and not buf_has_content) then
		vim.g.loaded_netrw = 1
		vim.g.loaded_netrwPlugin = 1
		vim.g.loaded_netrwSettings = 1
		vim.g.loaded_netrwFileHandlers = 1
		api.nvim_buf_delete(0, {})
		if is_dir then startdir = bufname end
		defer(function() M.toggle(cfg.replace_netrw) end, 0)
	end

	if ((cfg.picker.session or cfg.explorer.session) == "shared") then
		pickersession = " -S -s " .. sessionfile
		explorersession = pickersession
		cmd("autocmd VimLeavePre * call delete(fnameescape('".. sessionfile .."'))")
	else
		if cfg.picker.session == "global" then pickersession = " -S "
		elseif cfg.picker.session == "local" then
			pickersession = " -S -s " .. sessionfile .. "-picker"
			cmd("autocmd VimLeavePre * call delete(fnameescape('".. sessionfile .. "-picker'))")
		else pickersession = "" end

		if cfg.explorer.session == "global" then explorersession = " -S "
		elseif cfg.explorer.session == "local" then
			explorersession = " -S -s " .. sessionfile .. "-explorer"
			cmd("autocmd VimLeavePre * call delete(fnameescape('".. sessionfile .. "-explorer'))")
		else explorersession = "" end
	end

	cmd [[
		command! NnnPicker lua require("nnn").toggle("picker")
		command! NnnExplorer lua require("nnn").toggle("explorer")
		autocmd BufEnter * if &ft ==# "nnn" | startinsert | endif
		autocmd TermClose * if &ft ==# "nnn" | :bdelete! | endif
	]]
end

return M
