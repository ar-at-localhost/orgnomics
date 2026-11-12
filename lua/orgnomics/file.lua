local Promise = require("orgmode.utils.promise")
local OrgApiFile = require("orgmode.api.file")

---@class OrgApiFile
---@field insert_headline fun(self: OrgApiFile, headline: OrgApiHeadline | OrgHeadline | { text: string, level: integer }, after?: OrgApiHeadline | OrgHeadline, force_write?: boolean): OrgPromise<OrgApiHeadline>
function OrgApiFile:insert_headline(headline, after, force_write)
	return Promise.new(function(res)
		local bufnr = vim.fn.bufnr(self.filename)
		local exists = bufnr ~= -1

		if not exists then
			bufnr = vim.fn.bufadd(self.filename)
			vim.bo[bufnr].swapfile = false
			vim.fn.bufload(bufnr)
		end

		local insert_at

		if after then
			insert_at = after.position.end_line
		else
			local last = self.headlines[#self.headlines]
			if last then
				insert_at = last.position.end_line - 1
			else
				insert_at = 0
			end
		end

		local lines
		if headline.node then
			local text = vim.treesitter.get_node_text(headline.node, bufnr)
			lines = vim.split(text, "\n", { plain = true })
		else
			local stars = string.rep("*", headline.level or 1)
			lines = { stars .. " " .. headline.text }
		end

		vim.api.nvim_buf_set_lines(bufnr, insert_at, insert_at, false, lines)

		local reloaded = self:reload()
		local hl = reloaded:get_headline_on_line(insert_at + 1)
		res(hl or reloaded.headlines[#reloaded.headlines])

		local function cleanup()
			if not exists then
				vim.api.nvim_buf_delete(bufnr, { unload = true })
			end
		end

		if vim.bo[bufnr].modified or force_write then
			vim.api.nvim_buf_call(bufnr, function()
				vim.cmd("noautocmd silent! write!")
				vim.schedule(function()
					cleanup()
				end)
			end)
		else
			cleanup()
		end
	end)
end

return OrgApiFile
