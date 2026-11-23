-- Response policy and immutable, per-payload retry state for the HTTP publisher.
local lpeg = require 'lpeg'
local http_patterns = require 'lpeg_patterns.http'

local M = {}
local rules = {
	success           = { success = true,  max_retries = 0 },
	timeout           = { success = false, max_retries = math.huge },
	network_failure   = { success = false, max_retries = math.huge },
	request_timeout   = { success = false, max_retries = math.huge },
	rate_limited      = { success = false, max_retries = math.huge },
	server_failure    = { success = false, max_retries = math.huge },
	-- Temporary compatibility with cloud backends that report outages as 400.
	-- Remove this allowance once those backends consistently return 503 (#389).
	bad_request       = { success = false, max_retries = 3 },
	permanent_failure = { success = false, max_retries = 0 },
	invalid_response  = { success = false, max_retries = 0 },
}
local exceptions = { [400] = 'bad_request', [408] = 'request_timeout', [429] = 'rate_limited' }

function M.classify(status)
	if type(status) ~= 'string' and type(status) ~= 'number' then return 'invalid_response' end
	local code = tonumber(status)
	if not code or code % 1 ~= 0 or code < 100 or code > 599 then return 'invalid_response' end
	if code >= 200 and code < 300 then return 'success' end
	if code >= 500 then return 'server_failure' end
	return exceptions[code] or 'permanent_failure'
end

---@class HttpRetryState
---@field outcome string Normalised outcome; all 5xx share one outcome.
---@field success boolean
---@field retry number Additional attempts already made for this outcome.
---@field max_retries number

--- Observe an attempt's outcome without mutating the previous state.
--- Outcome changes reset the count and backoff. Three retries allow four attempts.
---@param previous HttpRetryState|nil
---@param outcome string
---@param one_shot? boolean
---@return HttpRetryState
function M.next(previous, outcome, one_shot)
	local rule = assert(rules[outcome], 'unknown HTTP outcome: ' .. tostring(outcome))
	return {
		outcome = outcome,
		success = rule.success,
		retry = previous and previous.outcome == outcome and previous.retry + 1 or 0,
		max_retries = one_shot and 0 or rule.max_retries,
	}
end

function M.is_exhausted(state)
	return not state.success and state.retry >= state.max_retries
end

local retry_after_pattern = http_patterns.Retry_After * -lpeg.P(1)
local month_days = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }

local function leap_year(year)
	return year % 4 == 0 and (year % 100 ~= 0 or year % 400 == 0)
end

local function leaps_before(year)
	return math.floor((year - 1) / 4) - math.floor((year - 1) / 100) + math.floor((year - 1) / 400)
end

-- Convert the parsed Gregorian date directly to UTC seconds, independently of
-- the device's local timezone and daylight-saving settings.
local function utc_seconds(date)
	local leap = leap_year(date.year)
	local days_in_month = month_days[date.month] + (date.month == 2 and leap and 1 or 0)
	if date.day < 1 or date.day > days_in_month or date.hour > 23 or date.min > 59 or date.sec > 60 then
		return nil
	end
	local days = 365 * (date.year - 1970) + leaps_before(date.year) - leaps_before(1970) + date.day - 1
	for month = 1, date.month - 1 do days = days + month_days[month] end
	if date.month > 2 and leap then days = days + 1 end
	return days * 86400 + date.hour * 3600 + date.min * 60 + date.sec
end

--- Backoff is capped at 60s; a valid Retry-After may extend it beyond that cap.
--- now is wall-clock UTC seconds; the caller sleeps on the monotonic fiber clock.
function M.delay(state, headers, now)
	local delay = math.min(2 ^ math.min(state.retry, 6), 60)
	for name, value in pairs(headers or {}) do
		if type(name) == 'string' and name:lower() == 'retry-after' and type(value) == 'string' then
			local parsed = retry_after_pattern:match(value:match('^%s*(.-)%s*$'))
			if type(parsed) == 'table' then
				local timestamp = utc_seconds(parsed)
				parsed = timestamp and timestamp - now or nil
			end
			if type(parsed) == 'number' and parsed < math.huge then delay = math.max(delay, parsed) end
			break
		end
	end
	return delay
end

return M
