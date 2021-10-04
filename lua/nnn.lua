local api = vim.api
local uv = vim.loop
local cmd = vim.cmd
local pickerregex = "term://.*nnn.*-p.*";
local fiforegex = "term://.*nnn.*-F1";
local curwin
local pickertmp = vim.fn.tempname() .. "-picker"
local fifotmp = vim.fn.tempname() .. "-explorer"
local opts = os.getenv("NNN_OPTS"):gsub("a", "")
local cfg = {
	cmd = "nnn",
	replace_netrw = false,
	filetype_exclude = {},
	default_mode = "explorer",
	explorer_width = 24,
	mappings = {}
}
local M = {}

local function is_buf_open(regex)
 	for _, buf in pairs(api.nvim_list_bufs()) do
		local buf_name = api.nvim_buf_get_name(buf)
		if string.match(buf_name, regex) ~= nil then return buf end
	end
	return nil
end

local function is_win_open(regex)
	for _, win in pairs(api.nvim_list_wins()) do
 		local buf = api.nvim_win_get_buf(win)
		local buf_name = api.nvim_buf_get_name(buf)
		if string.match(buf_name, regex) ~= nil then return buf end
  end
    return nil
end

local function get_win(regex)
 	for _, win in pairs(api.nvim_list_wins()) do
		local buf_name = api.nvim_buf_get_name(api.nvim_win_get_buf(win))
		if string.match(buf_name, regex) ~= nil then return win end
	end
  return nil
end

function M.close(regex)
  local win = get_win(regex)
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
					vim.defer_fn(function()
						if #api.nvim_list_wins() == 1 then
							local win = get_win()
							local portwidth = api.nvim_win_get_width(win)
							local width = portwidth - cfg.explorer_width
							cmd(width .. "vsplit " .. vim.fn.fnameescape(chunk:sub(1, -2)))
							curwin = api.nvim_tabpage_get_win(0)
							api.nvim_set_current_win(win)
							-- TODO replace workaround for nnn shifting out of viewport
							cmd("vertical " .. win .. "resize " .. portwidth)
							cmd("vertical " .. win .. "resize " .. width)
							api.nvim_feedkeys(api.nvim_replace_termcodes("<C-\\><C-n><C-W>l", true, true, true), "t", true)
						else
							api.nvim_set_current_win(curwin)
							cmd("edit " .. vim.fn.fnameescape(chunk:sub(1, -2)))
						end
					end, 0)
				else
					uv.fs_close(fd)
				end
			end)
		end
	end)
end

function M.mapping(action)
	api.nvim_feedkeys(api.nvim_replace_termcodes("<C-\\><C-n>", true, true, true), "t", true)
	api.nvim_set_current_win(curwin)
	vim.cmd(action)
	api.nvim_set_current_win(get_win())
	api.nvim_feedkeys(api.nvim_replace_termcodes("i<CR>", true, true, true), "t", true)
end

function M.open(regex)
	curwin = api.nvim_tabpage_get_win(0)
	local buf = is_buf_open(regex)
	if buf == nil then
		cmd("topleft" .. cfg.explorer_width .. "vsplit term://NNN_OPTS=" .. opts .. " NNN_FIFO=" .. fifotmp .. " " .. cfg.cmd .. " -F1")
		cmd("setlocal nonumber norelativenumber winfixwidth winfixheight noshowmode buftype=terminal filetype=nnn")
		api.nvim_buf_set_keymap(is_buf_open(regex), "t", "<C-l>", "<C-\\><C-n><C-w>l", {})
		for k, v in pairs(cfg.mappings) do
			api.nvim_buf_set_keymap(is_buf_open(regex), "t", k, "<C-\\><C-n><cmd>lua require('nnn').mapping('" .. v .."')<CR>", {})
		end
		read_fifo()
	else
		cmd("topleft" .. cfg.explorer_width .. "vsplit+" .. buf .. "buffer")
	end
	cmd("startinsert")
end

local function create_float()
	curwin = api.nvim_tabpage_get_win(0)
  local vim_height = vim.api.nvim_eval [[&lines]]
  local vim_width = vim.api.nvim_eval [[&columns]]

  local width = math.floor(vim_width * 0.8) + 5
  local height = math.floor(vim_height * 0.7) + 2
  local col = vim_width * 0.1 - 2
  local row = vim_height * 0.15 - 1
  local win = vim.api.nvim_open_win(0, true, {
      relative = 'editor',
      width = width,
      height = height,
      col = col,
      row = row,
      style = 'minimal',
      focusable = false
    })
	if #api.nvim_list_bufs() == 1 or is_buf_open(pickerregex) == nil then
		local buf = api.nvim_create_buf(true, false)
		cmd("keepalt b" .. buf)
	end
	return win
end

function M.on_exit()
	M.close(pickerregex)
	local fd = io.open(pickertmp, "r")
	if fd ~= nil then
		for line in io.lines(pickertmp) do
			cmd("edit " .. vim.fn.fnameescape(line))
		end
	else
		print("error exiting nnn")
	end
	io.close(fd)
end

local function open_picker(regex)
	local win = create_float()
	curwin = api.nvim_tabpage_get_win(0)
	local buf = is_buf_open(regex)
	if buf == nil then
		vim.fn.termopen("nnn -p " .. pickertmp, { on_exit = M.on_exit })
		--cmd("edit term://NNN_OPTS=" .. opts .. " " .. cfg.cmd .. " -p" .. fname)
		cmd("setlocal nonumber norelativenumber winfixwidth winfixheight noshowmode buftype=terminal filetype=nnn")
		api.nvim_buf_set_keymap(is_buf_open(regex), "t", "<C-l>", "<C-\\><C-n><C-w>l", {})
		for k, v in pairs(cfg.mappings) do
			api.nvim_buf_set_keymap(is_buf_open(regex), "t", k, "<C-\\><C-n><cmd>lua require('nnn').mapping('" .. v .."')<CR>", {})
		end
	else
		api.nvim_win_set_buf(win, buf)
	end
	cmd("startinsert")
end

function M.toggle(mode)
	if mode == nil then mode = cfg.default_mode end
	if mode == "explorer" then
		if is_win_open(fiforegex) then
			M.close(fiforegex)
		else
			M.open(fiforegex)
  	end
	elseif mode == "picker" then
		if is_win_open(pickerregex) then
			M.close(pickerregex)
		else
			open_picker(pickerregex)
		end
	end
end

function M.setup(setup_cfg)
	cmd [[
		command! NnnPicker lua require("nnn").toggle("picker")
		command! NnnToggle lua require("nnn").toggle()
		command! NnnOpen lua require("nnn").open()
		command! NnnClose lua require("nnn").close()
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
		vim.defer_fn(function() M.toggle("picker") end, 0)
	end
end

return M
