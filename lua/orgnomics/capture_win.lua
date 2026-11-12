---@class Global
---@field __orgnomics_capture_win snacks.win.Config
_G.__orgnomics_capture_win = {
	title = "Org Capture",
	border = "rounded",
	position = "float",
	relative = "editor",
	max_width = 92,
	max_height = 24,
}

---@param cfg? snacks.win.Config
local function capture_win(cfg)
	_G.__orgnomics_capture_win = vim.tbl_deep_extend("force", _G.__orgnomics_capture_win, cfg or {})

	return function(name)
		local bufnr = vim.api.nvim_create_buf(false, false)
		vim.api.nvim_buf_set_name(bufnr, name)
		return Snacks.win(vim.tbl_deep_extend("force", _G.__orgnomics_capture_win, { ft = "org", buf = bufnr }))
	end
end

return capture_win
