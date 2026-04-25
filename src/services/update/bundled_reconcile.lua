-- services/update/bundled_reconcile.lua
--
-- Converges a component towards the MCU image bundled with the current CM5
-- release.  This is intentionally small: it creates/starts/commits normal
-- update jobs and stores only the long-lived follow/hold policy state here.

local uuid = require 'uuid'

local M = {}
local Bundled = {}
Bundled.__index = Bundled

local function copy(v, seen)
	if type(v) ~= 'table' then return v end
	seen = seen or {}
	if seen[v] then return seen[v] end
	local out = {}
	seen[v] = out
	for k, vv in pairs(v) do out[copy(k, seen)] = copy(vv, seen) end
	return out
end

local function software_identity(component_state)
	local sw = type(component_state) == 'table' and component_state.software or nil
	if type(sw) ~= 'table' then return nil end
	if sw.image_id == nil then
		return nil
	end
	return {
		version = sw.version,
		build_id = sw.build,
		image_id = sw.image_id,
		boot_id = sw.boot_id,
	}
end

local function image_identity(inspected)
	local build = type(inspected) == 'table' and inspected.build or nil
	local payload = type(inspected) == 'table' and inspected.payload or nil
	if type(build) ~= 'table' then return nil end
	return {
		version = build.version,
		build_id = build.build_id,
		image_id = build.image_id,
	}
end

local function identities_match(current, desired)
	if not (type(current) == 'table' and type(desired) == 'table') then return false end
	return desired.image_id ~= nil and current.image_id == desired.image_id
end

local function cm5_release_id(ctx, cfg)
	local cm5 = ctx.observer:component_state_for('cm5')
	local sw = type(cm5) == 'table' and cm5.software or nil
	if type(sw) ~= 'table' then return nil end
	local field = cfg.cm5_release_id_field or 'image_id'
	return sw[field] or sw.image_id or sw.boot_id or sw.version
end

local function is_terminal(ctx, job)
	return job and ctx.model.is_terminal(job.state)
end

local function matching_job(ctx, component, desired)
	for _, id in ipairs(ctx.state.store.order) do
		local job = ctx.state.store.jobs[id]
		local meta = job and job.metadata or nil
		local b = type(meta) == 'table' and meta.bundled or nil
		if job and job.component == component and type(b) == 'table' then
			if desired.image_id and b.image_id == desired.image_id then
				return job
			end
		end
	end
	return nil
end

function M.new(ctx, commands, store)
	return setmetatable({ ctx = ctx, commands = commands, store = store }, Bundled)
end

function Bundled:save_record(component, rec)
	local ok, err = self.store:put(component, rec)
	if not ok then
		self.ctx.svc:obs_log('warn', { what = 'bundled_state_save_failed', component = component, err = tostring(err) })
		return nil, err
	end
	self.ctx.conn:retain({ 'state', 'update', 'bundled', component }, rec)
	return true, nil
end

function Bundled:mark_job_success(job, result)
	if not (job and job.component == 'mcu') then return end
	local meta = type(job.metadata) == 'table' and job.metadata or {}
	if meta.source == 'bundled' or type(meta.bundled) == 'table' then
		return
	end

	local rec = self.store:get(job.component) or {}
	local current_state = self.ctx.observer:component_state_for(job.component)
	local current = software_identity(current_state)
	local desired = type(rec.desired) == 'table' and rec.desired or nil
	rec.follow_mode = 'hold'
	if identities_match(current, desired) then
		rec.sync_state = 'satisfied'
		rec.last_result = 'manual_success_hold_satisfied'
	else
		rec.sync_state = 'diverged'
		rec.last_result = 'manual_success_hold'
	end
	rec.last_manual_job_id = job.job_id
	rec.updated_at = self.ctx.now()
	self:save_record(job.component, rec)
end

function Bundled:maybe_run()
	local cfg = self.ctx.state.cfg.bundled or {}
	local components = type(cfg.components) == 'table' and cfg.components or {}
	for component, bcfg in pairs(components) do
		if type(bcfg) == 'table' and bcfg.enabled == true then
			self:maybe_component(component, bcfg)
		end
	end
end

function Bundled:maybe_component(component, bcfg)
	if self.ctx.state.active_job or self.ctx.state.locks.global then return end

	local current_state = self.ctx.observer:component_state_for(component)
	if type(current_state) ~= 'table' or current_state.available == false then return end
	if current_state.ready ~= true then return end
	if not software_identity(current_state) then return end

	local artifact = { kind = 'bundled' }
	local ref, desc, aerr = self.ctx.artifacts:resolve_job_artifact({
		component = component,
		artifact = artifact,
		metadata = { source = 'bundled_probe' },
	})
	if not ref then
		self.ctx.svc:obs_log('warn', { what = 'bundled_artifact_unavailable', component = component, err = tostring(aerr) })
		return
	end
	-- Probe imports are not jobs.  They are transient and can be released after inspection.
	self.ctx.artifacts:delete(ref)

	local inspected = type(desc) == 'table' and desc.mcu_image or nil
	local desired = image_identity(inspected)
	if not desired then return end
	desired.source = 'bundled'
	desired.cm5_release_id = cm5_release_id(self.ctx, bcfg)

	local current = software_identity(current_state)
	local rec = self.store:get(component) or {}
	local follow = rec.follow_mode or bcfg.follow_mode_default or 'auto'
	rec.follow_mode = follow
	rec.desired = desired
	rec.updated_at = self.ctx.now()

	if identities_match(current, desired) then
		rec.sync_state = 'satisfied'
		rec.last_result = 'satisfied'
		self:save_record(component, rec)
		return
	end

	if follow == 'hold' then
		rec.sync_state = 'diverged'
		rec.last_result = 'held'
		self:save_record(component, rec)
		return
	end

	rec.sync_state = 'pending'
	self:save_record(component, rec)

	local job = matching_job(self.ctx, component, desired)
	if job and not is_terminal(self.ctx, job) then
		if job.state == 'created' then
			self.commands:start_job(job)
		elseif job.state == 'awaiting_commit' and job.auto_commit then
			self.commands:commit_job(job)
		end
		return
	end

	local new_job, err = self.commands:create_job_from_spec({
		job_id = tostring(uuid.new()),
		component = component,
		artifact_ref = nil,
		artifact_meta = nil,
		expected_image_id = desired.image_id,
		metadata = {
			source = 'bundled',
			bundled = copy(desired),
		},
		auto_start = bcfg.auto_start ~= false,
		auto_commit = bcfg.auto_commit ~= false,
	})
	if not new_job then
		self.ctx.svc:obs_log('warn', { what = 'bundled_job_create_failed', component = component, err = tostring(err) })
		return
	end
	-- Resolve and attach the fresh bundled artefact immediately.  create_job_from_spec
	-- is used so this helper can control metadata; the artefact source is still the
	-- normal bundled source.
	local aref, ameta, rerr = self.ctx.artifacts:resolve_job_artifact({
		component = component,
		artifact = { kind = 'bundled' },
		metadata = new_job.metadata,
	})
	if not aref then
		self.ctx.patch_job(new_job, { state = 'failed', stage = 'failed', error = tostring(rerr or 'bundled_artifact_failed') })
		return
	end
	new_job.artifact_ref = aref
	new_job.artifact_meta = ameta
	self.ctx.patch_job(new_job, { expected_image_id = desired.image_id })

	rec.last_attempt_job_id = new_job.job_id
	self:save_record(component, rec)

	if new_job.auto_start then
		self.commands:start_job(new_job)
	end
end

return M
