---@class OrgnomicsPickersOpts
---@field files? boolean | OrgFilePickerOpts
---@field headlines? boolean | OrgHeadlinesPickerConfig

---@class OrgnomicsPickers
local OrgnomicsPickers = {}

---@param opts OrgnomicsPickersOpts
function OrgnomicsPickers.setup(opts)
	local o = opts or {}
	local pickers = { files = "orgfiles", headlines = "orgheadlines" }

	for k, v in pairs(pickers) do
		if o[k] then
			local m = require("orgnomics." .. k)
			Snacks.picker.sources[v] = vim.tbl_deep_extend("force", m, o[k] == true and {} or o[k])
		end
	end
end

---@return OrgnomicsPickersOpts
function OrgnomicsPickers.default()
	return {
		files = true,
		headlines = true,
	}
end

return OrgnomicsPickers
