-- lua/orgnomics/autocheck.lua
local OrgDate = require("orgmode.objects.date")
local Promise = require("orgmode.utils.promise")
local helpers = require("orgnomics.helpers")

local uv = vim.uv or vim.loop
local TICK_MS = 15 * 1000
local KINDS = { "in", "out" }
local DEFAULTS = { ["in"] = "09:00", out = "17:00" } -- 24h: 17:00 == 05:00 PM

---@alias AutocheckKind "in"|"out"

---@class AutocheckOpts
---@field enabled? boolean Use the defaults (in = "09:00", out = "17:00") for any time not given
---@field in? string|false 24h "HH:MM"; false disables just this trigger
---@field out? string|false 24h "HH:MM"; false disables just this trigger
---@field confirm? fun(kind: AutocheckKind): boolean The only cancellation surface: called right before a trigger runs (never for one skipped because it already happened), return false to cancel it (for that day)
---@field on_late_checkin? fun(minutes_late: integer) Called after a late automatic check-in succeeds; return value ignored
---@field remind_before? integer|false Minutes (1-1439) before a trigger to call `on_remind`
---@field on_remind? fun(kind: AutocheckKind, minutes_left: integer) Notification hook only, the return value is ignored and it cannot cancel anything. Not called for a check-in that already happened today. Defaults to a Snacks notification

--- What Autocheck needs from whoever owns the clock (ClockManager satisfies this).
---@class AutocheckHost
---@field clock_in fun(self: AutocheckHost): any
---@field clock_out fun(self: AutocheckHost): any
---@field has_checked_in fun(self: AutocheckHost, from: OrgDate, to: OrgDate): OrgPromise<boolean> A check-in happened within the range (read from the org clock data, so it holds across sessions)
---@field has_checked_out fun(self: AutocheckHost, from: OrgDate, to: OrgDate): OrgPromise<boolean> A check-out happened within the range (read from the org clock data, so it holds across sessions)

---@class AutocheckTime
---@field hour integer
---@field min integer
---@field str string normalized "HH:MM"

---@class Autocheck
---@field private host AutocheckHost
---@field private confirm? fun(kind: AutocheckKind): boolean
---@field private on_late_checkin? fun(minutes_late: integer)
---@field private on_remind fun(kind: AutocheckKind, minutes_left: integer)
---@field private remind_before? integer
---@field private times table<AutocheckKind, AutocheckTime|nil>
---@field private fired table<AutocheckKind, string|nil> "YYYY-MM-DD" the trigger was last handled on
---@field private reminded table<AutocheckKind, string|nil> "YYYY-MM-DD" the reminder was sent on
---@field private timer? uv.uv_timer_t
local Autocheck = {}
Autocheck.__index = Autocheck

---@param msg string
---@param level? "info"|"error"
local function notify(msg, level)
	Snacks.notify(msg, { level = level or "info", title = "Orgnomics" })
end

---@param kind AutocheckKind
---@param minutes_left integer
local function default_on_remind(kind, minutes_left)
	notify(string.format("Auto check-%s in %d minute%s", kind, minutes_left, minutes_left == 1 and "" or "s"))
end

--- Validate / sanitize a 24h "HH:MM" string. Accepts "9:05", " 09:05 " -> "09:05".
---@param value any
---@return string? normalized
---@return string? err
local function sanitize_time(value)
	if value == nil or value == false then
		return nil
	end
	if type(value) ~= "string" then
		return nil, "expected a string in 24h format (HH:MM), got " .. type(value)
	end
	local h, m = vim.trim(value):match("^(%d%d?):(%d%d)$")
	h, m = tonumber(h), tonumber(m)
	if not h or h > 23 or m > 59 then
		return nil, string.format("invalid time %q, expected 24h format 00:00-23:59", value)
	end
	return string.format("%02d:%02d", h, m)
end

---@param date OrgDate
---@return string
local function day_key(date)
	return string.format("%04d-%02d-%02d", date.year, date.month, date.day)
end

--- True once today's HH:MM has been reached (minute granularity).
---@param now OrgDate
---@param t AutocheckTime
---@return boolean
local function elapsed(now, t)
	local target = now:clone():set({ hour = t.hour, min = t.min })
	return not target:is_after(now, "minute")
end

--- Whether the owner should start autocheck for these options.
---@param opts AutocheckOpts
---@return boolean
function Autocheck.is_enabled(opts)
	if opts.enabled == false then
		return false
	end
	return opts.enabled == true or opts["in"] ~= nil or opts.out ~= nil
end

---@param host AutocheckHost
---@param opts AutocheckOpts
---@return Autocheck
function Autocheck.new(host, opts)
	local self = setmetatable({
		host = host,
		confirm = opts.confirm,
		on_late_checkin = opts.on_late_checkin,
		on_remind = opts.on_remind or default_on_remind,
		times = {},
		fired = {},
		reminded = {},
	}, Autocheck)

	for _, kind in ipairs(KINDS) do
		local value = opts[kind]
		if value == nil and opts.enabled then
			value = DEFAULTS[kind]
		end
		self:_set(kind, value)
	end

	self:_set_remind_before(opts.remind_before)
	self:_validate_window()

	return self
end

function Autocheck:start()
	self:stop()
	self.timer = uv.new_timer()
	-- Polling (rather than a one-shot timer per trigger) survives laptop suspend and
	-- makes "already elapsed" and "scheduled" the same code path.
	self.timer:start(
		0,
		TICK_MS,
		vim.schedule_wrap(function()
			self:_tick()
		end)
	)
end

function Autocheck:stop()
	if self.timer then
		self.timer:stop()
		if not self.timer:is_closing() then
			self.timer:close()
		end
		self.timer = nil
	end
end

--- Set (or clear with nil/false) a trigger time. If the time has already elapsed today,
--- it fires on the first tick after start.
---@private
---@param kind AutocheckKind
---@param value? string|false
function Autocheck:_set(kind, value)
	local norm, err = sanitize_time(value)
	if err then
		notify(string.format("autocheck.%s: %s (disabled)", kind, err), "error")
	end

	if not norm then
		self.times[kind] = nil
		return
	end

	local h, m = norm:match("^(%d%d):(%d%d)$")
	self.times[kind] = {
		hour = tonumber(h) --[[@as integer]],
		min = tonumber(m) --[[@as integer]],
		str = norm,
	}
end

--- Minutes before a trigger at which `on_remind` is called. nil/false disables reminders.
---@private
---@param minutes? integer|false
function Autocheck:_set_remind_before(minutes)
	if minutes == nil or minutes == false then
		self.remind_before = nil
		return
	end
	if type(minutes) ~= "number" or minutes < 1 or minutes >= 24 * 60 then
		notify("autocheck.remind_before: expected minutes between 1 and 1439 (reminders disabled)", "error")
		self.remind_before = nil
		return
	end
	self.remind_before = math.floor(minutes)
end

--- check-out must be later than check-in within the same day.
---@private
function Autocheck:_validate_window()
	local i, o = self.times["in"], self.times.out
	if i and o and (o.hour * 60 + o.min) <= (i.hour * 60 + i.min) then
		notify(string.format("autocheck: out (%s) must be later than in (%s); out disabled", o.str, i.str), "error")
		self.times.out = nil
	end
end

---@private
function Autocheck:_tick()
	local now = OrgDate.now()
	local key = day_key(now)

	---@type table<AutocheckKind, boolean|nil>
	local due = {}
	for _, kind in ipairs(KINDS) do
		local t = self.times[kind]
		if t and self.fired[kind] ~= key and elapsed(now, t) then
			due[kind] = true
		end
	end

	-- Both already elapsed (e.g. set up after the work day ended): the window is over,
	-- checking in only to check out again would be noise.
	if due["in"] and due.out then
		self.fired["in"] = key
		due["in"] = nil
	end

	for _, kind in ipairs(KINDS) do
		if due[kind] then
			self:_run(kind, key, now)
		end
	end

	self:_tick_reminders(now, key)
end

--- Reminders are informational only: once per trigger per day, while the trigger is still
--- ahead and within `remind_before` minutes. Set up inside the window -> fires right away
--- with the actual minutes left. What the consumer does with it is up to them; the callback's
--- return value is ignored and nothing here can cancel a trigger (that is `confirm`'s job).
---@private
---@param now OrgDate
---@param key string
function Autocheck:_tick_reminders(now, key)
	if not self.remind_before then
		return
	end

	local now_min = now.hour * 60 + now.min
	for _, kind in ipairs(KINDS) do
		local t = self.times[kind]
		if t and self.fired[kind] ~= key and self.reminded[kind] ~= key then
			local left = t.hour * 60 + t.min - now_min
			if left > 0 and left <= self.remind_before then
				self.reminded[kind] = key
				self:_already_done(kind, now)
					:next(function(done)
						if done then
							return nil
						end

						local ok, err = pcall(self.on_remind, kind, left)
						if not ok then
							notify("autocheck on_remind failed: " .. tostring(err), "error")
						end

						return nil
					end)
					:catch(function(err)
						notify("autocheck reminder failed: " .. tostring(err), "error")
						return nil
					end)
			end
		end
	end
end

--- Whether `kind` already happened, judged from the org clock data so it holds across sessions.
--- in:  a check-in since the start of today.
--- out: a check-out since today's out time.
---@private
---@param kind AutocheckKind
---@param now OrgDate
---@return OrgPromise<boolean>
function Autocheck:_already_done(kind, now)
	if kind == "in" then
		return self.host:has_checked_in(now:start_of("day"), now)
	end

	local t = self.times[kind] --[[@as AutocheckTime]]
	local from = now:set({ hour = t.hour, min = t.min })

	-- Before the out time there is nothing to look at yet
	if now:is_before(from) then
		return Promise.resolve(false)
	end

	return self.host:has_checked_out(from, now)
end

---@private
---@param kind AutocheckKind
---@return boolean
function Autocheck:_confirmed(kind)
	if not self.confirm then
		return true
	end

	local ok, res = pcall(self.confirm, kind)
	if not ok then
		return false
	end

	return res and true or false -- false: cancelled by the consumer
end

---@private
---@param kind AutocheckKind
---@param key string
---@param now OrgDate
function Autocheck:_run(kind, key, now)
	local t = self.times[kind]

	if not t then
		return
	end

	local minutes_late = kind == "in" and (now.hour * 60 + now.min - t.hour * 60 - t.min) or 0
	-- Mark first: whatever happens below, never fire twice on the same day.
	self.fired[kind] = key

	self:_already_done(kind, now)
		:next(function(done)
			if done or (minutes_late == 0 and not self:_confirmed(kind)) then
				return nil
			end

			return helpers.get_active_clock():next(
				---@param active? OrgActiveClock
				function(active)
					local has_clock = active and active.headlineApi

					if kind == "in" then
						if has_clock then
							return nil -- already working on something, leave it alone
						end
						return Promise.resolve(self.host:clock_in()):next(function(result)
							if minutes_late > 0 and self.on_late_checkin then
								local ok, err = pcall(self.on_late_checkin, minutes_late)
								if not ok then
									notify("autocheck on_late_checkin failed: " .. tostring(err), "error")
								end
							end
							return result
						end)
					end

					if not has_clock then
						return nil
					end
					return self.host:clock_out()
				end
			)
		end)
		:catch(function(err)
			notify(string.format("autocheck %s failed: %s", kind, tostring(err)), "error")
			return nil
		end)
end

return Autocheck
