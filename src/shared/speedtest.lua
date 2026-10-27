-- Shared payload and lifetime limits for the network caller and HAL worker.
local M = {
	SETUP_S = 5,
	CLEANUP_S = 1,
	-- MAX_BYTES bounds data use; a 1 s window measured TCP ramp-up on high-RTT SIMs.
	MAX_DURATION_S = 4,
	MAX_BYTES = 1024 * 1024,
	MIN_BYTES = 16 * 1024,
	MIN_MEASUREMENT_S = 0.05,
}

function M.duration(value)
	local n = tonumber(value)
	if not n or n ~= n or n <= 0 or n > M.MAX_DURATION_S then return M.MAX_DURATION_S end
	return n
end

function M.timeout(value)
	return M.SETUP_S + M.duration(value) + M.CLEANUP_S
end

return M
