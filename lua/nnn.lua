local api = vim.api
local uv = vim.loop
local cmd = vim.cmd
local regex = "term://.*nnn.*";
local curwin
local fname = vim.fn.tempname()
local winwidth = 24
local cfg = {
	cmd = "nnn",
	replace_netrw = false
}
local M = {}

local function is_buf_open()
 	for _, buf in pairs(api.nvim_list_bufs()) do
		local buf_name = api.nvim_buf_get_name(buf)
		if string.match(buf_name, regex) ~= nil then
			return buf
		end
	end
	return nil
end

local function is_win_open()
	for _, win in pairs(api.nvim_list_wins()) do
 		local buf = api.nvim_win_get_buf(win)
		local buf_name = api.nvim_buf_get_name(buf)

		if string.match(buf_name, regex) ~= nil then return buf end
  end
    return nil
end

local function get_win()
 	for _, win in pairs(api.nvim_list_wins()) do
		local buf_name = api.nvim_buf_get_name(api.nvim_win_get_buf(win))
		if string.match(buf_name, regex) ~= nil then return win end
	end
  return nil
end

function M.close()
  local win = get_win()
  if not win then return end
	if #api.nvim_list_wins() ~= 1 then
  	api.nvim_win_close(win, true)
	else
		local buf = api.nvim_create_buf(false, false)
		api.nvim_win_set_buf(win, buf)
	end
end

local function read_fifo()
	uv.fs_open(fname, "r+", 438, function(ferr, fd)
		if ferr then
			print("Error opening pipe:" .. ferr)
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
							local width = portwidth - winwidth
							cmd(width .. "vsplit " .. vim.fn.fnameescape(chunk:sub(1, -2)))
							api.nvim_set_current_win(win)
							-- TODO replace workaround for nnn shifting out of viewport
							cmd("vertical " .. win .. "resize " .. portwidth)
							cmd("vertical " .. win .. "resize " .. width)
							local exitterm = api.nvim_replace_termcodes("<C-\\><C-n><C-w>l", true, true, true)
							api.nvim_feedkeys(exitterm, "t", true)
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

function M.open()
	curwin = api.nvim_tabpage_get_win(0)

	local buf = is_buf_open()
	if buf == nil then
		cmd("topleft" .. winwidth .. " vsplit term://NNN_FIFO=" .. fname .. " " .. cfg.cmd .. " -F1")
		cmd("setlocal nonumber norelativenumber winfixwidth winfixheight noshowmode buftype=terminal filetype=nnn")
		api.nvim_buf_set_keymap(is_buf_open(), "t", "<C-l>", "<C-\\><C-n><C-w>l", {})
		read_fifo()
	else
		cmd("topleft" .. winwidth .. "vsplit+" .. buf .. "buffer")
	end
	cmd("startinsert")
	api.nvim_win_set_cursor(get_win(), {1, 1})
end

function M.toggle()
	if is_win_open() then
		M.close()
	else
		M.open()
  end
end

function M.setup(setup_cfg)
	cmd [[
		command! NnnOpen lua require('nnn').open()
		command! NnnClose lua require('nnn').close()
		command! NnnToggle lua require('nnn').toggle()
		autocmd BufEnter * if &ft ==# 'nnn' | startinsert | endif
		autocmd TermClose * if &ft ==# 'nnn' | :bdelete! | endif
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
  --local buftype = api.nvim_buf_get_option(bufnr, "filetype")
  local stats = uv.fs_stat(bufname)
  local is_dir = stats and stats.type == "directory"
	local lines = not is_dir and api.nvim_buf_get_lines(bufnr, 0, -1, false) or {}
  local buf_has_content = #lines > 1 or (#lines == 1 and lines[1] ~= "")

	if (cfg.replace_netrw and is_dir) or (bufname == "" and not buf_has_content) then
		vim.g.loaded_netrw = 1
		vim.g.loaded_netrwPlugin = 1
		api.nvim_buf_delete(0, {})
		vim.defer_fn(function() M.open() end, 0)
	end
end

return M
