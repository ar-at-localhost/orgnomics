local orgmode = require("orgmode")
local orgmode_config = require("orgmode.config")
local api = require("orgmode.api")
local helpers = require("orgnomics.helpers")
local tbl = require("yalms.tbl")

---@class snacks.picker
---@field orgheadlines OrgHeadlinesPicker

---@class OrgHeadlinesPicker: snacks.Picker
---@field opts OrgHeadlinesPickerConfig

---@class OrgHeadlinesPickerConfig: snacks.picker.Config
---@field orgtags? string[]
---@field dirs? string[] directories to search
---@field sort OrgHeadlinesPickerSort?
---@field level integer
---@field file string?
---@field keywords string[]?
---@field _keywords table<string, string>?
---@field node? OrgHeadline
---@field actions OrgHeadlinesPickerActionsSpecs
---@field hooks? { after?: table<OrgHeadlinesPickerAction, fun(item: OrgHeadlinesPickerItem, picker: snacks.Picker, action?: OrgHeadlinesPickerAction)> }

---@class OrgHeadlinesPickerFindarCtx :snacks.picker.finder.ctx
---@field _opts OrgHeadlinesPickerConfig

---@alias OrgHeadlinesPickerActionsSpecs table<OrgHeadlinesPickerAction, snacks.picker.Action.spec>
---@alias OrgHeadlinesPickerAction 'priority_up' | 'priority_down' | 'toggle_clock' | 'refile' | 'refile_to_headline'

---@class OrgHeadlinesPickerFilter
---@field filter fun(item: OrgHeadlinesPickerItem, filter: OrgHeadlinesPickerFilterOpts):boolean?

---@class OrgHeadlinesPickerSort
---@field fields OrgHeadlinesPickerSortFields

---@class OrgHeadlinesPickerSortFields
---@field priority snacks.picker.sort.Field
---@field deadline snacks.picker.sort.Field

---@class OrgHeadlinesPickerFilterOpts
---@field level integer
---@field file string?
---@field keywords table<string, string>?
---@field node? OrgHeadline

---@class OrgHeadlinesPickerItem
---@field node OrgHeadline
---@field file string
---@field text string
---@field orgtags string[]
---@field tags_str string
---@field keyword string
---@field keyword_l string
---@field level integer
---@field priority integer
---@field deadline_unix integer
---@field preview snacks.picker.preview

local known_sorts = { "priority", "deadline", "level" }

---@type table<string, snacks.win.Keys>
local keys = {
	[">"] = {
		"depth_in",
		mode = { "i", "n" },
	},
	["<"] = {
		"depth_out",
		mode = { "i", "n" },
	},
	["="] = {
		"depth_reset",
		mode = { "i", "n" },
	},
	["<a-s>"] = {
		"cycle_sort",
		mode = { "i", "n", "v" },
	},
	["<M-+>"] = {
		"priority_up",
		mode = { "i", "n", "v" },
		desc = "Increase Priority",
	},
	["<M-->"] = {
		"priority_down",
		mode = { "i", "n", "v" },
		desc = "Decrease Priority",
	},
	["<M-k>"] = {
		"promote",
		mode = { "i", "n", "v" },
		desc = "Promote",
	},
	["<M-j>"] = {
		"demote",
		mode = { "i", "n", "v" },
		desc = "Demote",
	},
	["<M-t>"] = {
		"keyword_todo",
		mode = { "n", "v" },
		desc = "Status: TODO",
	},
	["<M-p>"] = {
		"keyword_prog",
		mode = { "n", "v" },
		desc = "Status: PROG (IN PROGRESS)",
	},
	["<M-d>"] = {
		"keyword_done",
		mode = { "n", "v" },
		desc = "Status: DONE",
	},
	["<M-c>"] = {
		"keyword_closed",
		mode = { "n", "v" },
		desc = "Status: CLOSED",
	},
	["<M-r>"] = {
		"refile",
		mode = { "n", "v" },
		desc = "Refile",
	},
	["<M-R>"] = {
		"refile_to_headline",
		mode = { "n", "v" },
		desc = "Refile to headline",
	},
	["<M-C>"] = {
		"toggle_clock",
		mode = { "n", "v" },
		desc = "Toggle clock",
	},
	["<M-x>"] = {
		"cancel_active_clock",
		mode = { "n", "v" },
		desc = "Cancel active clock",
	},
}

---@param cb fun(item: OrgHeadlinesPickerItem, picker: OrgHeadlinesPicker)
---@param kind? 'filter' | 'mutation' | 'done'
local function make_action(cb, kind)
	---@param picker OrgHeadlinesPicker
	---@param item OrgHeadlinesPickerItem
	return function(picker, item)
		cb(item, picker)

		if kind == "filter" then
			return picker:find()
		elseif kind == "mutation" then
			return picker:refresh()
		elseif kind == "done" then
			picker:close()
		end
	end
end

---@param keyword 'TODO' | 'PROG' | 'DONE' | 'CLOSED'
local function make_keyword_action(keyword)
	return make_action(function(item)
		local existing_keyword = item.node:get_todo()

		if existing_keyword and existing_keyword == keyword then
			Snacks.notify(string.format("Task has already %s status.", keyword), {
				title = "Task Keyword",
			})

			return
		end

		local title = item.text

		Snacks.notify(title .. " Setting status to " .. keyword, {
			title = "Orgnomics",
		})

		local headline_api = helpers.resolve_headline_api(item.node)
		if headline_api then
			item.node:set_todo(keyword)
		end

		vim.schedule(function()
			Snacks.notify(title .. " Status is now " .. keyword, {
				title = "Orgnomics",
			})
		end)
	end, "mutation")
end

---@type OrgHeadlinesPickerConfig
local picker = {
	level = 1,
	auto_confirm = false,
	auto_close = false,
	preview = "preview",

	---@param item OrgHeadlinesPickerItem
	---@param picker OrgHeadlinesPicker
	format = function(item, picker)
		return {
			{
				picker.opts._keywords[item.keyword_l and item.keyword_l] or "----",
				string.format("@org.keyword%s%s", item.keyword_l and "." or "", item.keyword_l or ""),
			},
			{ " " },
			{ item.text, string.format("@org.headline.level%d", item.level) },
			{ " " },
			{ item.tags_str, "@org.tag" },
		}
	end,

	---@param opts OrgHeadlinesPickerConfig
	---@return OrgHeadlinesPickerItem[]
	finder = function(opts)
		opts.level = opts.level or 1
		opts._keywords = opts._keywords
			or tbl.map(
				tbl.filter(orgmode_config.org_todo_keywords or {}, function(item)
					return item ~= "|"
				end),
				---@param item string
				function(item)
					return item:lower(), item:upper()
				end
			)

		local files = orgmode.files
		---@type OrgHeadlinesPickerItem[]
		local items = {}

		for _, f in pairs(files.files) do
			local headlines = f:get_headlines()

			for _, h in ipairs(headlines) do
				local keyword = h:get_todo() or ""
				local deadline = h:get_deadline_date()
				local priority = h:get_priority()
				local tags = h:get_tags()

				---@type OrgHeadlinesPickerItem
				local item = {
					node = h,
					file = f.filename,
					text = h:get_title(),
					keyword = keyword,
					keyword_l = keyword:lower(),
					level = h:get_level(),
					orgtags = tags,
					tags_str = table.concat(tags, " "),
					priority = helpers.priority_to_integer(priority),
					deadline = deadline,
					deadline_unix = (deadline and deadline.timestamp) or math.huge,
					---@diagnostic disable-next-line: assign-type-mismatch
					preview = {
						ft = "org",
						text = table.concat(h:get_lines(), "\n"),
					},
				}

				table.insert(items, item)
			end
		end

		if opts.dirs then
			for _, dir in ipairs(opts.dirs) do
				local d = vim.fs.normalize(dir)

				items = vim.tbl_filter(function(item)
					return vim.startswith(item.file, d)
				end, items)
			end
		end

		if opts.orgtags then
			for _, raw_tag in ipairs(opts.orgtags) do
				local neg = raw_tag:sub(1, 1) == "!"
				local tag = neg and raw_tag:gsub("^!", "") or raw_tag

				items = vim.tbl_filter(function(item)
					local has = tbl.arr_has(item.orgtags or {}, tag)
					return has ~= neg
				end, items)
			end
		end

		return vim.tbl_filter(function(item)
			local parent = item.node:get_parent_headline()
			local o = opts

			---@cast item OrgHeadlinesPickerItem
			return (item.level == o.level)
				and (not o.file or item.file == o.file)
				and (not o.keywords or not #o.keywords or o.keywords[item.keyword_l])
				and (not o.node or (parent and item.file == o.node.file.filename))
		end, items)
	end,

	win = {
		input = {
			keys = vim.tbl_extend("force", keys, {}),
		},
		list = {
			keys = vim.tbl_extend("force", keys, {}),
		},
	},

	actions = {
		depth_in = make_action(function(item, picker)
			local opts = picker.opts

			local childs = item.node:get_child_headlines()
			if #childs <= 0 then
				vim.notify("Task has no sub-tasks!", "warn")
				return
			end

			opts.node = item.node
			opts.level = opts.level + 1
		end, "filter"),

		depth_out = make_action(function(_, picker)
			local opts = picker.opts
			opts.node = opts.node and opts.node:get_parent_headline()
			opts.level = opts.level - 1

			if opts.level <= 1 then
				opts.level = 1
				opts.node = nil
			end
		end, "filter"),

		depth_reset = make_action(function(_, picker)
			local opts = picker.opts
			opts.node = nil
			opts.level = 1
		end, "filter"),

		cycle_sort = make_action(function(_, picker)
			local state = picker.opts
			local idx = 1

			for i, v in ipairs(known_sorts) do
				if v == state.sort then
					idx = i
					break
				end
			end

			idx = (idx % #known_sorts) + 1
			state.sort = {
				fields = {
					priority = {
						name = "priority",
					},
					deadline = {
						name = "priority",
					},
				},
			}
		end, "filter"),

		priority_up = make_action(function(item)
			local priority = item.node:get_priority()
			if priority and priority == "A" then
				Snacks.notify("Task is already at priority A.", {
					title = "Priority [A]",
				})
				return
			end

			local title = item.text

			Snacks.notify(title .. " Changing priority Up", {
				title = "Orgnomics",
			})

			local headline_api = helpers.resolve_headline_api(item.node)
			if headline_api then
				headline_api:priority_up()
			end

			vim.schedule(function()
				local new_priority = item.node:get_priority() or "none"
				Snacks.notify(title .. " Priority is now " .. new_priority, {
					title = "Orgnomics",
				})
			end)
		end, "mutation"),

		priority_down = make_action(function(item)
			local priority = item.node:get_priority()

			if priority and priority == "C" or priority == "" then
				Snacks.notify(
					string.format(
						"Task is already at%s priority%s.",
						priority == "" and " lowest" or "",
						priority ~= "" and (string.format("Priority [%s]", priority)) or ""
					),
					{
						title = priority == "" and "Priority Down" or "Priority " .. priority,
					}
				)
				return
			end

			local title = item.text

			Snacks.notify(title .. " Changing priority Down", {
				title = "Orgnomics",
			})

			local headline_api = helpers.resolve_headline_api(item.node)
			if headline_api then
				headline_api:priority_down()
			end

			vim.schedule(function()
				local new_priority = item.node:get_priority() or "none"
				Snacks.notify(title .. " Priority is now " .. new_priority, {
					title = "Orgnomics",
				})
			end)
		end, "mutation"),

		keyword_todo = make_keyword_action("TODO"),
		keyword_prog = make_keyword_action("PROG"),
		keyword_done = make_keyword_action("DONE"),
		keyword_closed = make_keyword_action("CLOSED"),

		toggle_clock = make_action(function(item, picker)
			local headline_api = helpers.resolve_headline_api(item.node)

			if headline_api then
				headline_api
					:is_clocked_in()
					:next(function(clocked_in)
						return headline_api:toggle_clock():next(function()
							return clocked_in
						end)
					end)
					:next(function()
						pcall(function()
							picker.opts.hooks.after.toggle_clock(item, picker, "toggle_clock")
						end)

						return nil
					end)
			end
		end),

		cancel_active_clock = make_action(function(item)
			local headline_api = helpers.resolve_headline_api(item.node)

			if headline_api then
				headline_api:cancel_active_clock()
			end
		end, "mutation"),

		promote = make_action(function(item, picker)
			local title = item.text

			Snacks.notify(title .. " Promoting", {
				title = "Orgnomics",
			})

			local headline_api = helpers.resolve_headline_api(item.node) --[[@as OrgApiHeadline]]

			if headline_api.level <= 1 then
				return
			end

			if headline_api then
				picker.opts.level = picker.opts.level - 1
				headline_api:promote()
			end

			vim.schedule(function()
				Snacks.notify(title .. " Promoted", {
					title = "Orgnomics",
				})
			end)
		end, "mutation"),

		demote = make_action(function(item, picker)
			local title = item.text

			Snacks.notify(title .. " Demoting", {
				title = "Orgnomics",
			})

			local headline_api = helpers.resolve_headline_api(item.node) -->[[as OrgApiHeadline]]

			if headline_api then
				picker.opts.level = picker.opts.level + 1
				headline_api:demote()
			end

			vim.schedule(function()
				Snacks.notify(title .. " Demoted", {
					title = "Orgnomics",
				})
			end)
		end, "mutation"),

		refile = make_action(function(item, this_picker)
			local title = item.text

			Snacks.notify(title .. " Refiling...", {
				title = "Orgnomics",
			})

			local opts = this_picker.opts

			Snacks.picker.orgfiles({
				dirs = opts.dirs,
				confirm = function(picker, file_item)
					local headline_api = helpers.resolve_headline_api(item.node)
					local file_api = helpers.resolve_file_api(file_item.file)

					if headline_api and file_api then
						api.refile({
							source = headline_api,
							destination = file_api,
						}):next(function()
							picker:close()
							vim.schedule(function()
								Snacks.notify(title .. " Refiled to " .. file_item.file, {
									title = "Orgnomics",
								})
							end)

							pcall(function()
								this_picker.opts.hooks.after.refile(item, this_picker, "refile")
							end)
						end)
					end
				end,
			})
		end, "done"),

		---@param item OrgHeadlinesPickerItem
		refile_to_headline = make_action(function(item, this_picker)
			local title = item.text

			Snacks.notify(title .. " Refiling to headline...", {
				title = "Orgnomics",
			})

			local opts = this_picker.opts

			Snacks.picker.orgfiles({
				confirm = function(_, file_item)
					Snacks.picker.orgheadlines({
						dirs = opts.dirs,
						file = file_item.file,
						level = 1,
						confirm = function(picker, dest_item)
							local source_headline_api = helpers.resolve_headline_api(item.node)
							local des_headline_api = helpers.resolve_headline_api(dest_item.node)

							if source_headline_api and des_headline_api then
								api.refile({
									source = source_headline_api,
									destination = des_headline_api,
								}):next(function()
									pcall(function()
										picker:close()

										vim.schedule(function()
											Snacks.notify(title .. " Refiled to " .. dest_item.text, {
												title = "Orgnomics",
											})
										end)

										pcall(function()
											this_picker.opts.hooks.after.refile(item, this_picker, "refile_to_headline")
										end)
									end)
								end)
							end
						end,
					})
				end,
			})
		end, "done"),
	},

	---@param picker OrgHeadlinesPicker
	on_show = function(picker)
		orgmode.files:load(true):wait()
		picker:find()
		picker:focus()

		Snacks.notify("Org Headlines Ready.", {
			title = "Orgnomics",
		})
	end,

	on_close = function() end,
}

---@type snacks.picker.Config
local M = vim.tbl_extend("force", {}, picker)

return M
