local headers = require 'services.http.headers'

local M = {}

local function eq(a, b, msg)
	if a ~= b then error((msg or 'assertion failed') .. ': expected ' .. tostring(b) .. ', got ' .. tostring(a), 2) end
end

local function ok(v, msg)
	if not v then error(msg or 'assertion failed', 2) end
	return v
end

function M.test_status_headers_round_trip_to_table()
	local h = ok(headers.status(201, { ['content-type'] = 'text/plain' }))
	eq(headers.get_one(h, ':status'), '201')
	eq(headers.get_one(h, 'content-type'), 'text/plain')
	local t = headers.to_table(h)
	eq(t[':status'], '201')
	eq(t['content-type'], 'text/plain')
end

function M.test_request_helpers_set_pseudo_headers_and_repeated_values()
	local h = ok(headers.request('POST', '/upload', 'example.test', 'https', {
		['x-test'] = { 'a', 'b' },
	}))
	eq(headers.get_one(h, ':method'), 'POST')
	eq(headers.get_one(h, ':path'), '/upload')
	local all = headers.get_all(h, 'x-test')
	eq(#all, 2)
	eq(all[1], 'a')
	eq(all[2], 'b')
end

return M
