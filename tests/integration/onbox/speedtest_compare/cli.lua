local process = require 'onbox.support.process'
local util = require 'onbox.support.util'

local M = {}
local VERSION = '1.2.1'
M.label = 'LibreSpeed CLI (Rust) v' .. VERSION
local ARCHIVES = {
	aarch64 = { 'aarch64-unknown-linux-musl', '1f15cd8a0d96c8383b7fde26bb36f24747f4473ee03cdcf3e32d814719e309a0' },
	armv7l = { 'armv7-unknown-linux-musleabihf', '49bdddf22d8d37ebf40b9fc08b7aff2e9ecc03b1c49c44ced12170cb5a42fd65' },
	x86_64 = { 'x86_64-unknown-linux-musl', 'c71f75867d0d25554860675d09408b809a19d0b96ef221ecea6283ee9a6eb1ee' },
}
local quote = process.quote

function M.install(box)
	local arch = util.trim(box.ssh:run('uname -m', { timeout = 15 }).stdout)
	local release = assert(ARCHIVES[arch], 'No pinned LibreSpeed CLI build for ' .. arch)
	box.ssh:run([[awk '$2 == "/tmp" && $3 == "tmpfs" { found=1 } END { exit !found }' /proc/mounts]],
		{ timeout = 15 })
	local artifacts = box.artifacts
	local name = 'librespeed-cli-' .. release[1]
	local url = ('https://github.com/librespeed/speedtest-cli-rust/releases/download/v%s/%s.tar.gz'):format(VERSION, name)
	local archive = artifacts .. '/librespeed-cli.tar.gz'
	local binary = artifacts .. '/librespeed-cli'
	local downloaded = box.process:run('curl -fsSL --max-time 45 --max-filesize 4194304 --output ' .. quote(archive)
		.. ' --url ' .. quote(url), { timeout = 50, log_path = artifacts .. '/speedtest-cli-download.log' })
	assert(downloaded.code == 0, 'Unable to download LibreSpeed CLI (see speedtest-cli-download.log)')
	local checksum = box.process:run('sha256sum ' .. quote(archive), { timeout = 15 })
	assert(checksum.code == 0 and checksum.stdout:match('^(%x+)') == release[2], 'LibreSpeed archive checksum mismatch')
	local extracted = box.process:run('tar -xzOf ' .. quote(archive) .. ' ' .. quote(name .. '/librespeed-cli')
		.. ' > ' .. quote(binary), { timeout = 15 })
	assert(extracted.code == 0, 'Unable to extract LibreSpeed CLI: ' .. extracted.stderr)
	local remote_binary = box.remote .. '/librespeed-cli'
	box.ssh:upload(binary, remote_binary)
	box.ssh:upload(box.args.here .. '/bounded_exec.lua', box.remote .. '/speedtest-deadline.lua')
	box.ssh:run('chmod 700 ' .. quote(remote_binary) .. ' && ' .. quote(remote_binary) .. ' --version', { timeout = 15 })
end

return M
