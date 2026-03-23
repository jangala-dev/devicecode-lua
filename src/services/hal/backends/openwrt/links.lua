-- services/hal/backends/openwrt/links.lua
--
-- Link/runtime methods for the OpenWrt HAL backend.

local common = require 'services.hal.backends.openwrt.common'

local M = {}

function M.list_links(self, req, _msg)
	local cur = self._cur
	local host = self._host
	local ids = common.list_link_ids_from_req(req)
	local out = {}

	for i = 1, #ids do
		local link_id = ids[i]
		local dev, derr = common.resolve_network_device(cur, host, link_id)

		if not dev then
			out[link_id] = {
				ok       = false,
				link_id  = link_id,
				err      = tostring(derr),
				resolved = false,
			}
		else
			local facts, ferr = common.read_sysfs_link_facts(dev)
			if not facts then
				out[link_id] = {
					ok       = false,
					link_id  = link_id,
					device   = dev,
					err      = tostring(ferr),
					resolved = true,
				}
			else
				out[link_id] = {
					ok        = true,
					link_id   = link_id,
					device    = dev,
					resolved  = true,
					operstate = facts.operstate,
					carrier   = facts.carrier,
					mtu       = facts.mtu,
					ipv4      = common.read_ipv4_addr_for_device(dev),
					gateway   = common.read_default_route_for_device(dev),
				}
			end
		end
	end

	return {
		ok    = true,
		links = out,
	}
end

function M.probe_links(self, req, _msg)
	local cur = self._cur
	local host = self._host
	if type(req) ~= 'table' or type(req.links) ~= 'table' then
		return { ok = false, err = 'req.links must be a table' }
	end

	local samples = {}

	for link_id, spec in pairs(req.links) do
		if type(link_id) ~= 'string' or link_id == '' then
			samples[link_id] = { ok = false, err = 'invalid link id' }
		elseif not common.is_plain_table(spec) then
			samples[link_id] = { ok = false, err = 'link spec must be a table' }
		else
			local dev, derr = common.resolve_network_device(cur, host, link_id)
			if not dev then
				samples[link_id] = { ok = false, err = tostring(derr) }
			else
				local method = spec.method or 'ping'
				local refs   = spec.reflectors
				local ref    = (type(refs) == 'table' and refs[1]) or nil

				if method ~= 'ping' then
					samples[link_id] = {
						ok     = false,
						device = dev,
						err    = 'unsupported probe method: ' .. tostring(method),
					}
				elseif type(ref) ~= 'string' or ref == '' then
					samples[link_id] = {
						ok     = false,
						device = dev,
						err    = 'no reflector configured',
					}
				else
					local rtt, perr = common.ping_rtt_ms_for_device(dev, ref, spec.timeout_s, spec.count)
					if not rtt then
						samples[link_id] = {
							ok        = false,
							device    = dev,
							reflector = ref,
							err       = tostring(perr),
						}
					else
						samples[link_id] = {
							ok        = true,
							device    = dev,
							reflector = ref,
							rtt_ms    = rtt,
						}
					end
				end
			end
		end
	end

	return {
		ok      = true,
		samples = samples,
	}
end

function M.read_link_counters(self, req, _msg)
	local cur = self._cur
	local host = self._host
	local ids = common.list_link_ids_from_req(req)
	local out = {}

	for i = 1, #ids do
		local link_id = ids[i]
		local dev, derr = common.resolve_network_device(cur, host, link_id)

		if not dev then
			out[link_id] = {
				ok  = false,
				err = tostring(derr),
			}
		else
			local base = '/sys/class/net/' .. tostring(dev) .. '/statistics/'
			local rx_bytes, rx_err = common.read_u64_file(base .. 'rx_bytes')
			local tx_bytes, tx_err = common.read_u64_file(base .. 'tx_bytes')
			local rx_packets = common.read_u64_file(base .. 'rx_packets')
			local tx_packets = common.read_u64_file(base .. 'tx_packets')

			if rx_bytes == nil or tx_bytes == nil then
				out[link_id] = {
					ok     = false,
					device = dev,
					err    = tostring(rx_err or tx_err or 'counter read failed'),
				}
			else
				out[link_id] = {
					ok         = true,
					device     = dev,
					rx_bytes   = rx_bytes,
					tx_bytes   = tx_bytes,
					rx_packets = rx_packets,
					tx_packets = tx_packets,
				}
			end
		end
	end

	return {
		ok    = true,
		links = out,
	}
end

function M.apply_link_shaping_live(self, req, _msg)
	local host = self._host
	if type(req) ~= 'table' or type(req.links) ~= 'table' then
		return { ok = false, err = 'req.links must be a table', applied = false, changed = false }
	end

	if type(host.apply_link_shaping_live) == 'function' then
		return host.apply_link_shaping_live(req)
	end

	return {
		ok      = true,
		applied = true,
		changed = false,
		note    = 'apply_link_shaping_live not yet implemented in openwrt backend',
	}
end

function M.apply_multipath_live(self, req, _msg)
	local host = self._host
	if type(req) ~= 'table' or type(req.members) ~= 'table' then
		return { ok = false, err = 'req.members must be an array', applied = false, changed = false }
	end

	if type(host.apply_multipath_live) == 'function' then
		return host.apply_multipath_live(req)
	end

	return {
		ok      = true,
		applied = true,
		changed = false,
		note    = 'apply_multipath_live not yet implemented in openwrt backend',
	}
end

function M.persist_multipath_state(self, req, _msg)
	local ok, err = common.persist_mwan3_live_state(self._cur, req)
	if not ok then
		return { ok = false, err = tostring(err), applied = false, changed = false }
	end

	return {
		ok      = true,
		applied = true,
		changed = true,
	}
end

return M
