---@class OrgnomicsKeywordsOpts Keywords with todo_ prefix are Todo state keywords, while other are Done state keywords
---@field t_prog? boolean PROG keyword
---@field t_break? boolean BREAK keyword
---@field t_checkin? boolean CHECKIN keyword
---@field closed? boolean CLOSED keyword

---@class OrgnomicsKeywords
local OrgnomicsKeywords = {}

---@param opts OrgnomicsKeywordsOpts
function OrgnomicsKeywords.setup(opts)
	opts = opts or OrgnomicsKeywords:default()
	local orgmode = require("orgmode")
	local orgmode_config = require("orgmode.config")
	local tbl = require("yalms.tbl")

	local keywords = orgmode_config.org_todo_keywords or { "TODO", "|", "DONE" }

	for _, v in ipairs({ "_prog", "_checkin", "_break" }) do
		if opts[v] then
			local kw = v:upper():gsub("^_", "")
			if not tbl.arr_has(keywords, kw) then
				table.insert(keywords, 1, kw)
			end
		end
	end

	for _, v in ipairs({ "closed" }) do
		if opts[v] then
			local kw = v:upper()
			if not tbl.arr_has(keywords, kw) then
				table.insert(keywords, kw)
			end
		end
	end

	orgmode.setup({
		org_todo_keywords = keywords,
	})
end

---@return OrgnomicsKeywordsOpts
function OrgnomicsKeywords.default()
	return {
		prog = true,
		closed = true,
	}
end

return OrgnomicsKeywords
