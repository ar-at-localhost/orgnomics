local org = require("orgmode")
local OrgApiHeadline = require("orgmode.api.headline")

---@class OrgApiHeadline
---@field set_todo fun(self: OrgApiHeadline, keyword: string)
function OrgApiHeadline:set_todo(keyword)
	---@diagnostic disable-next-line: invisible
	self:_do_action(function()
		local headline = org.files:get_closest_headline()
		headline:set_todo(keyword)
	end)
end

---@class OrgApiHeadline
---@field clock_in fun(self: OrgApiHeadline): OrgPromise
function OrgApiHeadline:clock_in()
	---@diagnostic disable-next-line: invisible
	return self:_do_action(function()
		local headline = org.files:get_closest_headline()

		if headline:is_clocked_in() then
			return
		end

		headline:clock_in()
	end)
end

---@class OrgApiHeadline
---@field clock_out fun(self: OrgApiHeadline): OrgPromise
function OrgApiHeadline:clock_out()
	---@diagnostic disable-next-line: invisible
	return self:_do_action(function()
		local headline = org.files:get_closest_headline()

		if not headline:is_clocked_in() then
			return
		end

		headline:clock_out()
	end)
end

---@class OrgApiHeadline
---@field is_clocked_in fun(self: OrgApiHeadline): OrgPromise
function OrgApiHeadline:is_clocked_in()
	local clock_in

	return self
		---@diagnostic disable-next-line: invisible
		:_do_action(function()
			local headline = org.files:get_closest_headline()
			clock_in = headline:is_clocked_in()
		end)
		:next(function()
			return clock_in
		end)
end

---@class OrgApiHeadline
---@field toggle_clock fun(self: OrgApiHeadline): OrgPromise
function OrgApiHeadline:toggle_clock()
	---@diagnostic disable-next-line: invisible
	return self:_do_action(function()
		local headline = org.files:get_closest_headline()
		return headline:is_clocked_in() and headline:clock_out() or headline:clock_in()
	end)
end

---@class OrgApiHeadline
---@field cancel_active_clock fun(self: OrgApiHeadline)
function OrgApiHeadline:cancel_active_clock()
	---@diagnostic disable-next-line: invisible
	self:_do_action(function()
		local headline = org.files:get_closest_headline()
		return headline:is_clocked_in() and headline:cancel_active_clock()
	end)
end

---@class OrgApiHeadline
---@field promote fun(self: OrgApiHeadline, amount?: number, recursive?: boolean)
function OrgApiHeadline:promote(amount, recursive)
	---@diagnostic disable-next-line: invisible
	self:_do_action(function()
		amount = amount or 1
		recursive = recursive or true
		local headline = org.files:get_closest_headline()
		return headline:promote(amount, recursive, false)
	end)
end

---@class OrgApiHeadline
---@field demote fun(self: OrgApiHeadline, amount?: number, recursive?: boolean)
function OrgApiHeadline:demote(amount, recursive)
	---@diagnostic disable-next-line: invisible
	self:_do_action(function()
		amount = amount or 1
		recursive = recursive or true
		local headline = org.files:get_closest_headline()
		return headline:demote(amount, recursive, false)
	end)
end

---@class OrgApiHeadline
---@field get_closest_headline OrgPromise<OrgHeadline>
function OrgApiHeadline:get_closest_headline()
	local Promise = require("orgmode.utils.promise")
	return Promise.new(function(res)
		---@diagnostic disable-next-line: invisible
		self:_do_action(function()
			res(org.files:get_closest_headline())
		end)
	end)
end

---@class OrgApiHeadline
---@field get_lines OrgPromise<string>
function OrgApiHeadline:get_lines()
	---@diagnostic disable-next-line: invisible
	return self:get_closest_headline():next(function(headline)
		return headline:get_lines() or {}
	end)
end

---@class OrgApiHeadline
---@field get_content OrgPromise<string>
function OrgApiHeadline:get_content()
	---@diagnostic disable-next-line: invisible
	return self:get_lines():next(function(lines)
		return table.concat(lines or {}, "\n")
	end)
end

return OrgApiHeadline
