---@diagnostic disable: duplicate-doc-field, duplicate-set-field
local Table = require("orgmode.files.elements.table")
local Duration = require("orgmode.objects.duration")

---@alias ClockReportFilter fun(file: OrgFile, headline: OrgHeadline): boolean

---@class OrgClockReport
---@field from OrgDate
---@field to OrgDate
---@field filter? ClockReportFilter
---@field table OrgTable
---@field files OrgFiles
local ClockReport = {}

---@param opts { from: OrgDate, to: OrgDate, files: OrgFiles, filter?: ClockReportFilter }
---@return OrgClockReport
function ClockReport:new(opts)
	opts = opts or {}
	local data = {}
	data.from = opts.from
	data.to = opts.to
	data.files = opts.files
	data.filter = opts.filter
	setmetatable(data, self)
	self.__index = self
	return data
end

---@param start_line number
---@return OrgTable
function ClockReport:get_table_report(start_line)
	local report = self:generate_report()
	local data = {
		{ "File", "Headline", "Time" },
		"hr",
		{ "", "ALL Total time", report.total_duration:to_string() },
		"hr",
	}

	for _, file in ipairs(report.files_with_clocks) do
		table.insert(data, { { value = file.name }, "File time", file.total_duration:to_string() })
		for _, headline in ipairs(file.headlines) do
			table.insert(data, {
				"",
				{ value = headline:get_title(), reference = headline },
				headline:get_logbook():get_total(self.from, self.to):to_string(),
			})
		end
		table.insert(data, "hr")
	end

	return Table.from_list(data, start_line, 0):compile()
end

function ClockReport:generate_report()
	local total_duration = 0
	local files_with_clocks = {}
  local visited = {}

	for _, orgfile in ipairs(self.files:all()) do
    if visited[orgfile.filename] then
      goto continue
    end

		local file_clocks = self:_get_clock_report_for_file(orgfile)
		if #file_clocks.headlines > 0 then
			total_duration = total_duration + file_clocks.total_duration.minutes
			table.insert(files_with_clocks, {
				name = orgfile:get_category() .. ".org",
				total_duration = file_clocks.total_duration,
				headlines = file_clocks.headlines,
			})
		end

    ::continue::
	end

	return {
		total_duration = Duration.from_minutes(total_duration),
		files_with_clocks = files_with_clocks,
	}
end

---@private
---@param orgfile OrgFile
function ClockReport:_get_clock_report_for_file(orgfile)
	local total_duration = 0
	local headlines = {}
	for _, headline in ipairs(orgfile:get_headlines()) do
		if not self.filter or self.filter(orgfile, headline) then
			local logbook = headline:get_logbook()
			if logbook then
				local minutes = logbook:get_total_minutes(self.from, self.to)
				if minutes > 0 then
					table.insert(headlines, headline)
					total_duration = total_duration + minutes
				end
			end
		end
	end

	return {
		headlines = headlines,
		total_duration = Duration.from_minutes(total_duration),
	}
end

return ClockReport
