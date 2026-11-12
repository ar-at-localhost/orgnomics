---@class OrgnomicsOpts
---@field keywords OrgnomicsKeywordsOpts
---@field pickers? OrgnomicsPickersOpts|boolean
---@field capture_win? true | snacks.win.Config
---@field clock? OrgnomicsClockOpts|true

---@class OrgnomicsClockOpts
---@field org_dir string Base directory for org files (required)
---@field tag? string (default "orgnomics")
---@field breaks_tag? string (default "break")
---@field breaks_file? string (default "breaks.org", relative to org_dir)
---@field exports_dir? string (default "exports", relative to org_dir)
---@field checkin_task? string (default "No active task")
---@field autocheck? AutocheckOpts

---@class Global
---@field __orgnomics_opts? OrgnomicsOpts
---@type OrgnomicsOpts
_G = _G or {}

---@class Orgnomics
local Orgnomics = {
	_opts = nil,
}

---@param opts? OrgnomicsOpts|true
function Orgnomics.setup(opts)
	local _ = require("snacks")
	if not _ then
		error("Snacks is not installed!")
	end

	local orgmode = require("orgmode")
	if not orgmode then
		error("Orgmode is not installed!")
	end

	require("orgnomics.file")
	require("orgnomics.headline")

	opts = (not opts or opts == true) and {
		pickers = true,
		capture_win = true,
		clock = true,
	} or opts

	_G.__orgnomics_opts = opts ---[[@as OrgnomicsOpts]]

	---@cast opts OrgnomicsOpts
	if opts.keywords then
		local OrgnomicsKeywords = require("orgnomics.keywords")
		OrgnomicsKeywords.setup(opts.keywords == true and OrgnomicsKeywords.default() or opts.keywords)
	end

	if opts.pickers then
		local pickers = require("orgnomics.pickers")
		pickers.setup(opts.pickers == true and pickers.default() or opts.pickers --[[@as OrgnomicsPickersOpts]])
	end

	if opts.capture_win then
		local config = require("orgmode.config")

		if config then
			config.win_split_mode = require("orgnomics.capture_win")(
				(opts.capture_win == true and {} or opts.capture_win) --[[@as snacks.win.Config]]
			)

			orgmode.setup(config)
		end
	end

	if opts.clock then
		if not _G.__orgnomics_clock then
			local ClockManager = require("orgnomics.clock")
			local clock_opts = opts.clock == true and { org_dir = vim.fn.stdpath("data") .. "/org" } or opts.clock
			_G.__orgnomics_clock = ClockManager:new(clock_opts)
		end

		local clock = _G.__orgnomics_clock

		vim.api.nvim_create_user_command("OrgnomicsBreak", function(o)
			local args = vim.split(o.args, "%s+", { trimempty = true })
			local pick = args[1] == "pick"
			local memo = args[1] == "memo"

			clock:clock_in({ pick = pick, memo = memo, is_break = true })
		end, { nargs = "*", force = true })

		vim.api.nvim_create_user_command("OrgnomicsClockIn", function(o)
			local args = vim.split(o.args, "%s+", { trimempty = true })
			local pick = args[1] == "pick"
			local memo = args[1] == "memo"

			clock:clock_in({ pick = pick, memo = memo, is_break = false })
		end, { nargs = "*", force = true })

		vim.api.nvim_create_user_command("OrgnomicsClockOut", function()
			clock:clock_out()
		end, { nargs = 0, force = true })

		vim.api.nvim_create_user_command("OrgnomicsClockStatus", function()
			clock:clock_status()
		end, { nargs = "?", force = true })

		vim.api.nvim_create_user_command("OrgnomicsSwitchTask", function()
			clock:clock_in({ pick = true })
		end, { nargs = 0, force = true })

		vim.api.nvim_create_user_command("OrgnomicsSummarize", function(o)
			clock:summarize(o.args and o.args ~= "" and o.args or "d")
		end, { nargs = "?", force = true })

		vim.api.nvim_create_user_command("OrgnomicsEditClock", function()
			clock:edit_checked_in_task()
		end, { nargs = 0, force = true })
	end

	orgmode:init()
	orgmode.files:load_sync()
end

function Orgnomics.get_clock()
	return _G.__orgnomics_clock
end

function Orgnomics.teardown()
	if _G.__orgnomics_clock then
		_G.__orgnomics_clock = nil
	end

	pcall(function()
		vim.api.nvim_del_user_command("OrgnomicsClockIn")
		vim.api.nvim_del_user_command("OrgnomicsClockOut")
		vim.api.nvim_del_user_command("OrgnomicsBreak")
		vim.api.nvim_del_user_command("OrgnomicsSwitchTask")
		vim.api.nvim_del_user_command("OrgnomicsSummarize")
		vim.api.nvim_del_user_command("OrgnomicsEditClock")
	end)

	if Snacks.picker.sources["orgfiles"] then
		Snacks.picker.sources["orgfiles"] = nil
	end
	if Snacks.picker.sources["orgheadlines"] then
		Snacks.picker.sources["orgheadlines"] = nil
	end
end

return Orgnomics
