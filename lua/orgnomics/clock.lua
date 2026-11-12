local OrgDate = require("orgmode.objects.date")
local orgmode = require("orgmode")
local Promise = require("orgmode.utils.promise")
local orgmode_config = require("orgmode.config")
local Capture = require("orgmode.capture")
local Template = require("orgmode.capture.template")
local helpers = require("orgnomics.helpers")
local ClockReport = require("orgnomics._clock")
local Autocheck = require("orgnomics.autocheck")

local tbl = require("yalms.tbl")
local fs = require("yalms.fs")
local str = require("yalms.str")
local EventEmitter = require("yalms.events.emitter")

local function resolve_rel_path(base_dir, rel_path)
	if not rel_path or rel_path == "" then
		return nil
	end
	if rel_path:sub(1, 1) == "/" then
		return rel_path
	end
	return base_dir .. "/" .. rel_path
end

---@class ClockManagerOpts
---@field org_dir string Base directory for org files (required)
---@field breaks_tag? string
---@field clock_file? string (default "breaks.org", relative to org_dir)
---@field exports_dir? string (default "exports", relative to org_dir)
---@field checkin_task_title? string
---@field break_types string[]
---@field default_break? string
---@field autocheck? AutocheckOpts

---@class ClockManagerRt: ClockManagerOpts
---@field org_dir string
---@field breaks_tag string
---@field clock_file string
---@field exports_dir string
---@field checkin_task string
---@field break_types string[]
---@field last_known_clock? OrgApiHeadline

---@class ClockManager: EventEmitter, AutocheckHost
---@field _opts ClockManagerOpts
---@field private _rt ClockManagerRt
---@field private _autocheck? Autocheck
ClockManager = {}
ClockManager.__index = ClockManager
setmetatable(ClockManager, { __index = EventEmitter })

function ClockManager:new(opts)
	opts = opts or {}
	local obj = EventEmitter.new(self)
	---@cast obj ClockManager
	obj._opts = opts
	obj:_init_events()
	obj:_init(opts)
	return obj
end

function ClockManager:_init_events()
	for _, event in ipairs({ "clock_in", "clock_out", "break_added" }) do
		self:on(event, function()
			self:emit("change", self)
		end)
	end
end

---@private
---@param opts ClockManagerOpts
function ClockManager:_init(opts)
	local dir = vim.fn.expand(opts.org_dir or string.format("%s/orgfiles", vim.fn.getcwd()))

	---@type ClockManagerOpts
	local defaults = {
		tag = "orgnomics",
		breaks_tag = "break",
		org_dir = vim.fn.expand("~/orgfiles"),
		clock_file = resolve_rel_path(dir, "clocks.org"),
		exports_dir = resolve_rel_path(dir, "exports"),
		break_types = {},
		default_break = "Time-Off",
		checkin_task = "No active task",
	}

	self._rt = vim.tbl_deep_extend("force", defaults, opts, {
		org_dir = dir,
	}) --[[@as ClockManagerRt]]

	local config = self._rt
	fs.touch(config.clock_file, true)

	local dirs = orgmode_config.org_agenda_files

	if config.org_dir then
		local pattern = string.format("%s/**/*.org", config.org_dir)
		dirs = (type(dirs) == "table" and dirs) or { dirs }
		if not helpers.dir_is_covered(dirs, pattern) then
			table.insert(dirs, pattern)
		end
	end

	local org_capture_templates = orgmode_config.org_capture_templates or {}
	if not org_capture_templates["orgnomics_break"] then
		org_capture_templates["orgnomics_break"] = {
			description = "Break",
			template = string.format("* BREAK %%? :%s:", config.breaks_tag),
			target = config.clock_file,
		}
	end

	if not org_capture_templates["orgnomics_work"] then
		org_capture_templates["orgnomics_work"] = {
			description = "Task",
			template = string.format("* TODO %%?"),
			target = config.clock_file,
		}
	end

	require("orgnomics.keywords").setup({
		["_break"] = true,
		_checkin = true,
	})

	orgmode.setup({
		org_capture_templates = org_capture_templates,
		org_agenda_files = dirs,
	})

	self:_sync_break_types()

	if opts.autocheck and Autocheck.is_enabled(opts.autocheck) then
		self._autocheck = Autocheck.new(self, opts.autocheck)
		self._autocheck:start()
	end
end

function ClockManager:get_config()
	return self._rt
end

function ClockManager:set_captured(headline)
	_G.__orgnomics_captured = headline
end

function ClockManager:get_captured()
	return _G.__orgnomics_captured
end

function ClockManager:get_checked_in_task()
	return self._rt.last_known_clock
end

---@return OrgPromise<OrgApiHeadline>
---@param opts? { pick?: boolean, memo?: boolean, captured?: boolean, is_break?: boolean, template?: string, file?: string, dirs?: string[] }
function ClockManager:clock_in(opts)
	opts = opts or {}
	local should_break = opts.is_break or false
	local on_break = false

	return Promise.resolve()
		:next(function()
			return helpers.get_active_clock():next(function(res)
				if res and res.headlineApi then
					on_break = self:is_break(res.headlineApi)

					if (not on_break) and should_break then
						self._rt.last_known_clock = res.headlineApi
					end

					return res.headlineApi:clock_out()
				end

				return opts
			end)
		end)
		:next(function()
			if opts.pick then
				return self:_pick(should_break, opts.dirs, opts.file)
			elseif opts.memo then
				return self:_memo(should_break, opts.template, opts.file)
			elseif should_break and on_break and self._rt.last_known_clock then
				return self._rt.last_known_clock
			elseif should_break then
				return self:get_default_break()
			else
				return self:get_checkin_task()
			end
		end)
		:next(
			---@param headline OrgApiHeadline
			function(headline)
				if not headline then
					error("No headline found!")
				end

				return headline:clock_in():catch(function()
					return headline
				end)
			end
		)
		:next(function()
			vim.defer_fn(function()
				orgmode.files:reload():next(function()
					vim.cmd("redraw!")
					local msg = should_break and "Break toggled" or "Clocked in"
					Snacks.notify(msg, { title = "Orgnomics" })
				end)
			end, 0)
		end)
		:next(function()
			if should_break then
				self:emit("break_added", self)
			else
				self:emit("clock_in", self)
			end
		end)
		:catch(function(err)
			local msg = type(err) == "string" and err:gsub("^[^:]+:%d+: ", "") or tostring(err)
			Snacks.notify(msg, { level = "error", title = "Orgnomics" })
		end)
end

---@param is_break? boolean
---@param dirs? string[]
---@param file? string
function ClockManager:_pick(is_break, dirs, file)
	return Promise.new(function(resolve)
		Snacks.picker.orgheadlines({
			dirs = dirs,
			file = is_break and self._rt.clock_file or file,
			orgtags = { (is_break and "" or "!") .. self._rt.breaks_tag },
			auto_confirm = false,
			auto_close = false,
			---@param picker OrgHeadlinesPicker
			---@param item OrgHeadlinesPickerItem
			confirm = function(picker, item)
				resolve(helpers.resolve_headline_api(item.node))
				picker:close()
			end,
		})
	end)
end

---@param is_break boolean
---@param template_name? string
---@param file? string
function ClockManager:_memo(is_break, template_name, file)
	local file_api = helpers.resolve_file_api(
		file or (is_break and self._rt.clock_file) or (orgmode_config.org_default_notes_file or "notes.org")
	) --[[@as OrgApiFile]]

	local template_key = (is_break and "orgnomics_break") or (template_name or "orgnomics_work")
	local template = vim.deepcopy(orgmode_config.org_capture_templates[template_key])
	template.target = file or file_api.filename
	if not template then
		error("No " .. template_key .. " template registered.")
	end

	local template_obj = Template:new(template)
	local old_headlines_count = #file_api.headlines

	return Promise.new(function(res, rej)
		local capture = Capture:new({
			files = orgmode.files,
			templates = { templates = template_obj },
			on_post_refile = function()
				orgmode.files:reload(file_api.filename):next(function()
					file_api = file_api:reload()
					local new_headlines = file_api.headlines

					if #new_headlines > old_headlines_count then
						return res(new_headlines[#new_headlines])
					end

					rej("Cancelled")
				end)
			end,
		})

		capture:open_template(Template:new(template)):next(function()
			vim.cmd("redraw!")
		end)
	end)
end

function ClockManager:clock_out()
	return helpers
		.get_active_clock()
		:next(function(res)
			if res and res.headlineApi then
				return res.headlineApi:clock_out()
			end

			return Promise.reject("No active clock!")
		end)
		:next(function()
			vim.defer_fn(function()
				orgmode.files:reload():next(function()
					vim.cmd("redraw!")
					Snacks.notify("Clocked out", { title = "Orgnomics" })
				end)
			end, 0)
			return nil
		end)
		:next(function()
			self:emit("clock_out", self)
			return nil
		end)
		:catch(function(err)
			local msg = type(err) == "string" and err:gsub("^[^:]+:%d+: ", "") or tostring(err)
			Snacks.notify(msg, { level = "error", title = "Orgnomics" })
			return nil
		end)
end

---@alias Period 'd' | 'w' | 'm'
---@param period Period
---@param win_cfg? snacks.win.Config
function ClockManager:summarize(period, win_cfg)
	local index = { d = "day", w = "week", m = "month" }
	period = period or "d"
	local to = OrgDate.now():clone():end_of("day")
	local from = to:start_of("day")

	if period == "w" then
		from = from:start_of("week")
	elseif period == "m" then
		from = from:start_of("month")
	end

	local checkin_as_working = true
	local buf = vim.api.nvim_create_buf(false, true)

	local function render()
		local report = ClockReport:new({
			from = from,
			to = to,
			files = orgmode.files,

			filter = function(_, h)
				local a = helpers.resolve_headline_api(h)
				if not a then
					return false
				end

				return (not self:is_break(a)) or (checkin_as_working and self:is_checkin_task(a))
			end,
		})

		local breaks = ClockReport:new({
			from = from,
			to = to,
			files = orgmode.files,

			filter = function(_, h)
				local a = helpers.resolve_headline_api(h)
				if not a then
					return false
				end

				return self:is_break(a) or ((self:is_checkin_task(a)) and not checkin_as_working)
			end,
		})

		local wreport = report:get_table_report(1)
		local breport = breaks:get_table_report(1)
		local lines = string.format(
			[[* Orgnomics

** Breaks
%s

** Work
%s]],
			table.concat(breport:draw(), "\n"),
			table.concat(wreport:draw(), "\n")
		)

		vim.bo[buf].modifiable = true
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, str.split(lines, "\n"))
		vim.bo[buf].modifiable = false
	end

	---@type snacks.win.Keys
	local keys = {
		q = "nop",
		["<Esc>"] = "nop",
		["<M-q>"] = "close",
		["<M-d>"] = "Daily",
		["<M-w>"] = "Weekly",
		["<M-m>"] = "Monthly",
	}

	---@param scope Period
	local render_action = function(scope)
		vim.schedule(function()
			period = scope
			to = OrgDate.now():end_of("day")
			from = to:clone():subtract({ [index[period]] = 1 }):start_of("day")
			render()
		end)
	end

	---@type table<string, snacks.win.Action.spec>
	local actions = {
		["Daily"] = function()
			render_action("d")
		end,
		["Weekly"] = function()
			render_action("w")
		end,
		["Monthly"] = function()
			render_action("m")
		end,
		["close"] = function(win)
			win:close()
		end,
		["nop"] = function() end,
	}

	Snacks.win(vim.tbl_deep_extend("force", win_cfg or {}, {
		floating = true,
		width = 120,
		height = 32,
		keys = keys,
		actions = actions,
	} --[[@as snacks.win.Config]], {
		title = "Orgnomics Summary",
		title_pos = "center",
		border = "rounded",
		buf = buf,
		ft = "org",
		bo = {
			filetype = "org",
			readonly = false,
			modifiable = false,
			buftype = "nofile",
			bufhidden = "wipe",
		},
		wo = {
			wrap = false,
			cursorline = true,
			number = false,
			relativenumber = false,
			signcolumn = "no",
		},
		position = "float",
		relative = "editor",
	} --[[@as snacks.win.Config]]))

	return Promise.new(function()
		vim.schedule(function()
			render()
		end)
	end)
end

function ClockManager:_sync_break_types()
	local rt = self._rt
	local break_types = tbl.deep_copy(rt.break_types)

	if not tbl.arr_has(break_types, rt.checkin_task) then
		table.insert(break_types, rt.checkin_task)
	end

	if not tbl.arr_has(break_types, rt.default_break) then
		table.insert(break_types, rt.default_break)
	end

	local filename = rt.clock_file
	fs.touch(filename)

	local function resolve()
		return orgmode.files:reload(filename):next(function()
			local file = orgmode.files:get(filename)
			local file_api = file and helpers.resolve_file_api(filename)
			if not file or not file_api then
				error("Failed to create or retrieve breaks file!")
			end

			return { file = file, file_api = file_api }
		end)
	end

	local promise = Promise:resolve()
	for _, title in ipairs(break_types) do
		promise = promise
			:next(function()
				return resolve()
			end)
			:next(function(files)
				local headline = files.file:find_headline_by_title(title)

				if not headline then
					return files.file_api:insert_headline({
						level = 1,
						text = string.format(
							"%s %s :%s:",
							(title == rt.checkin_task and "CHECKIN") or "BREAK",
							title,
							(title == rt.checkin_task and "checkin") or "break"
						),
					}, nil, true)
				end

				return files
			end)
	end

	promise:wait()
end

function ClockManager:clock_status()
	helpers
		:get_active_clock()
		---@param status OrgActiveClock
		:next(function(status)
			if not status then
				error("No active clock!")
			end

			Snacks.notify(
				string.format(
					"  %s\n----\nSince: %s",
					status.headline:get_title(),
					status.clock_info.start_time:format()
				),
				{ level = "info", title = "Orgnomics" }
			)

			return true
		end)
		:catch(function(err)
			local msg = type(err) == "string" and err:gsub("^[^:]+:%d+: ", "") or tostring(err)
			Snacks.notify(msg, { level = "error", title = "Orgnomics" })
			return true
		end)
end

---@param headline OrgApiHeadline
---@param title? string
function ClockManager:is_break(headline, title)
	return headline.todo_value == "BREAK"
		and tbl.arr_has(headline.tags, self._rt.breaks_tag)
		and (not title or headline.title == title)
end

---@param headline OrgApiHeadline
function ClockManager:is_checkin_task(headline)
	return headline.todo_value == "CHECKIN"
		and headline.title == self._rt.checkin_task
		and tbl.arr_has(headline.tags, "checkin")
end

---@return OrgPromise<OrgApiHeadline>
function ClockManager:get_default_break()
	return orgmode.files:reload(self._rt.clock_file):next(
		---@param file OrgFile
		function(file)
			for _, item in ipairs(file:get_headlines() or {}) do
				local api = helpers.resolve_headline_api(item) --[[@as OrgApiHeadline]]
				if self:is_break(api, self._rt.default_break) then
					return api
				end
			end
		end
	)
end

---@return OrgPromise<OrgApiHeadline>
function ClockManager:edit_checked_in_task()
	return helpers
		.get_active_clock()
		:next(function(res)
			if not (res and res.headlineApi) then
				error("No active clock!")
			end

			if self:is_break(res.headlineApi) then
				error("Cannot edit a break task!")
			end

			return res.headlineApi
		end)
		:next(function(headline)
			return orgmode
				.files
				:reload(headline.file.filename)
				:next(function()
					return headline:get_closest_headline()
				end)
				---@param hl OrgHeadline
				:next(function(hl)
					local start_row = hl:node():range()
					local lines = hl:get_lines()
					return {
						range = { start_row = start_row, end_row = start_row + #lines },
						lines = lines,
						headline = headline,
					}
				end)
		end)
		:next(
			---@param data { range: { start_row: integer, end_row: integer }, lines: string[], path: string, headline: OrgApiHeadline }
			function(data)
				local path = vim.fn.tempname()
				vim.fn.writefile(data.lines, path)

				return orgmode.files:load_file(path):next(function()
					data.path = path
					return data
				end)
			end
		)
		:next(
			---@param data { range: { start_row: integer, end_row: integer }, lines: string[], path: string, headline: OrgApiHeadline }
			function(data)
				return Promise.new(function(res)
					require("orgnomics.capture_win")

					vim.defer_fn(function()
						Snacks.win(vim.tbl_deep_extend("force", _G.__orgnomics_capture_win, {
							file = data.path,
							ft = "org",
							bo = {
								modifiable = true,
							},
							on_close = function()
								local content = vim.fn.readfile(data.path)
								local buf = vim.fn.bufnr(data.headline.file.filename)

								if buf == -1 then
									buf = vim.fn.bufadd(data.headline.file.filename)
								end

								vim.api.nvim_buf_set_lines(
									buf,
									data.range.start_row,
									data.range.end_row + 1,
									false,
									content
								)

								pcall(function()
									vim.api.nvim_buf_call(buf, function()
										vim.cmd("write")
									end)
								end)
								res()
							end,
						}))
					end, 0)
				end)
			end
		)
		:catch(function(err)
			local msg = type(err) == "string" and err:gsub("^[^:]+:%d+: ", "") or tostring(err)
			Snacks.notify(msg, { level = "error", title = "Orgnomics" })
			return true
		end)
end

---@return OrgPromise<OrgApiHeadline>
function ClockManager:get_checkin_task()
	return orgmode.files:reload(self._rt.clock_file):next(
		---@param file OrgFile
		function(file)
			for _, item in ipairs(file:get_headlines() or {}) do
				local api = helpers.resolve_headline_api(item) --[[@as OrgApiHeadline]]
				if self:is_checkin_task(api) then
					return api
				end
			end
		end
	)
end

---@param headline OrgApiHeadline
---@return OrgLogbook?
function ClockManager:_get_logbook(headline)
	local file = orgmode.files:get(headline.file.filename)

	return file:get_closest_headline({ headline.position.start_line, 0 }):get_logbook()
end

--- A check-in is a clock entry on the check-in task, read from the org files (survives sessions).
---@param from OrgDate
---@param to OrgDate
---@return OrgPromise<boolean>
function ClockManager:has_checked_in(from, to)
	return self:get_checkin_task():next(
		---@param headline? OrgApiHeadline
		function(headline)
			local logbook = headline and self:_get_logbook(headline)

			for _, item in ipairs(logbook and logbook.items or {}) do
				if item.start_time:is_between(from, to) then
					return true
				end
			end

			return false
		end
	)
end

--- A check-out has no entry of its own: it is a clock entry that ended within the range and was
--- not followed by another one starting right away (that would just be a task switch).
---@param from OrgDate
---@param to OrgDate
---@return OrgPromise<boolean>
function ClockManager:has_checked_out(from, to)
	return Promise.resolve():next(function()
		local starts = {}
		local ends = {}

		for _, file in ipairs(orgmode.files:all()) do
			for _, headline in ipairs(file:get_headlines()) do
				local logbook = headline:get_logbook()

				for _, item in ipairs(logbook and logbook.items or {}) do
					table.insert(starts, item.start_time.timestamp)

					if item.end_time and item.end_time:is_between(from, to) then
						table.insert(ends, item.end_time.timestamp)
					end
				end
			end
		end

		for _, stop in ipairs(ends) do
			local switched = false

			-- clock times are minute precise, so allow a minute between stopping and starting
			for _, start in ipairs(starts) do
				if start >= stop and start - stop <= 60 then
					switched = true
					break
				end
			end

			if not switched then
				return true
			end
		end

		return false
	end)
end

function ClockManager:switch_task()
	Snacks.picker.orgheadlines({
		level = 1,
		hooks = {
			after = {
				["toggle_clock"] = function(_, picker)
					pcall(function()
						picker:close()
					end)
					vim.defer_fn(function()
						orgmode.files:reload():next(function()
							vim.cmd("redraw!")
						end)
					end, 0)
				end,
			},
		},
	})
end

return ClockManager
