-- Runs on the box inside mwan3's interface binding, with a deadline that
-- survives exec and does not depend on the management SSH session.
local ffi = require 'ffi'
ffi.cdef[[
	typedef int pid_t;
	pid_t fork(void);
	pid_t getpid(void);
	pid_t getppid(void);
	int prctl(int option, unsigned long a, unsigned long b, unsigned long c, unsigned long d);
	int execvp(const char *file, const char *const argv[]);
	pid_t waitpid(pid_t pid, int *status, int options);
	int kill(pid_t pid, int sig);
	int usleep(unsigned int usec);
	void _exit(int status);
]]
local libc = ffi.C
local bit = require 'bit'
local SIGKILL, EINTR, WNOHANG, PR_SET_PDEATHSIG = 9, 4, 1, 1
local seconds = assert(tonumber(arg[1]))
assert(seconds > 0 and seconds < math.huge, 'Invalid CLI deadline')
local device, source = arg[2], arg[3]
assert(device:match('^[%w_.:%-]+$'), 'Invalid Linux network device')
assert(os.getenv('DEVICE') == device and os.getenv('SRCIP') == source, 'mwan3 selected a different device or source IP')
local mark_text = os.getenv('FWMARK') or ''
local hex_mark = mark_text:match('^0[xX](%x+)$')
local mark = hex_mark and tonumber(hex_mark, 16) or tonumber(mark_text:match('^(%d+)$'))
assert(mark and mark > 0 and mark <= 0xffffffff, 'Invalid mwan3 firewall mark')
local function check_address()
	local addresses = assert(io.popen('ip -4 addr show dev ' .. device, 'r'))
	local count, found = 0, nil
	for line in addresses:lines() do
		local address = line:match('%sinet%s+([%d.]+)/')
		if address then count, found = count + 1, address end
	end
	assert(addresses:close() and count == 1 and found == source, 'Selected device does not have exactly the expected IPv4')
end
check_address()
-- This static executable needs to apply mwan3's socket options itself.
local args = { './librespeed-cli', '--interface', device, '--fwmark', ('%.0f'):format(mark) }
for index = 4, #arg do args[#args + 1] = arg[index] end
local argv = ffi.new('const char *[?]', #args + 1)
for index, value in ipairs(args) do argv[index - 1] = value end

local function now()
	local uptime = assert(io.open('/proc/uptime', 'r'))
	local elapsed = uptime:read('*n')
	uptime:close()
	return assert(elapsed, 'Cannot read monotonic clock')
end

local deadline = now() + seconds
local parent = libc.getpid()
local child = libc.fork()
assert(child >= 0, 'Cannot start watchdog child')
if child == 0 then
	-- Terminate even if only the wrapper loses its SSH process.
	if libc.prctl(PR_SET_PDEATHSIG, SIGKILL, 0, 0, 0) ~= 0 or libc.getppid() ~= parent then libc._exit(126) end
	libc.execvp(argv[0], argv)
	libc._exit(127)
end

local status = ffi.new('int[1]')
while true do
	local completed = libc.waitpid(child, status, WNOHANG)
	if completed == child then
		local signal = bit.band(status[0], 127)
		local code = signal == 0 and bit.rshift(status[0], 8) or 128 + signal
		if code == 0 then
			check_address()
			-- Older mwan3 can report success even when its wrapped command failed.
			io.stdout:write('\nONBOX_LIBRESPEED_OK\n')
		end
		os.exit(code)
	end
	assert(completed >= 0 or ffi.errno() == EINTR, 'Cannot wait for speedtest CLI')
	if now() >= deadline then
		libc.kill(child, SIGKILL)
		while libc.waitpid(child, status, 0) < 0 and ffi.errno() == EINTR do end
		io.stderr:write('LibreSpeed CLI exceeded its deadline\n')
		os.exit(124)
	end
	libc.usleep(100000)
end
