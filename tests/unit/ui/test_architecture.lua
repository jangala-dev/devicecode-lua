-- tests/unit/ui/test_architecture.lua

local tests = {}

local function fail(msg) error(msg or 'assertion failed', 2) end

local function read_file(path)
	local f = assert(io.open(path, 'r'))
	local s = f:read('*a')
	f:close()
	return s
end

local function scan_files(root)
	local p = io.popen(('find %s -type f -name "*.lua"'):format(root))
	local out = {}
	for line in p:lines() do out[#out + 1] = line end
	p:close()
	return out
end

function tests.test_ui_service_code_does_not_use_infrastructure_waits()
	for _, path in ipairs(scan_files('../src/services/ui')) do
		local s = read_file(path)
		if s:find('perform_raw', 1, true) then fail(path .. ' uses perform_raw') end
		if s:find('join_op', 1, true) then fail(path .. ' uses join_op') end
		if s:find('close_op', 1, true) then fail(path .. ' uses close_op') end
	end
end

function tests.test_ui_no_longer_owns_http_transport_backend()
	local p = io.popen('find ../src/services/ui -type f -name "*.lua"')
	for path in p:lines() do
		local s = read_file(path)
		if s:find("services.ui.transport", 1, true) then fail(path .. ' still depends on UI transport') end
		if s:find("services.http.transport", 1, true) then fail(path .. ' reaches into HTTP transport internals') end
		if s:find("require 'cqueues", 1, true) or s:find('require "cqueues', 1, true) then fail(path .. ' requires cqueues') end
		if s:find("require 'http%.", 1) or s:find('require "http%.', 1) then fail(path .. ' requires raw lua-http') end
	end
	p:close()
end

function tests.test_ui_public_entry_has_no_websocket_export_for_first_cut()
	local s = read_file('../src/services/ui.lua')
	if s:find('services.ui.transport', 1, true) then fail('ui.lua exports UI transport') end
	if s:find('services.ui.ws', 1, true) then fail('ui.lua exports WebSocket modules in first cut') end
	if not s:find("services.ui.http.sse", 1, true) then fail('ui.lua does not export SSE helper') end
end

function tests.test_http_listener_consumes_http_sdk_not_transport()
	local s = read_file('../src/services/ui/http/listener.lua')
	if not s:find("services.http'.sdk", 1, true) and not s:find('services.http".sdk', 1, true) then
		fail('http listener does not consume services.http.sdk')
	end
	if s:find('run_pump', 1, true) then fail('http listener still owns a transport pump') end
	if s:find('cqueues', 1, true) or s:find('lua_http', 1, true) then fail('http listener mentions backend internals') end
	if not s:find('obtain_listener_op', 1, true) then fail('http listener lacks cap/http listen boundary') end
	if not s:find('http_request_rejected', 1, true) then fail('http listener lacks explicit overload rejection path') end
end


function tests.test_ui_listener_lifecycle_uses_service_event_ports()
	local service = read_file('../src/services/ui/service.lua')
	if not service:find('devicecode.support.service_events', 1, true) then fail('ui service does not use service event helper') end
	if not service:find('events_port = service_events.port', 1, true) then fail('ui listener is not wired through an event port') end
	if not service:find('listener_id', 1, true) or not service:find('listener_generation', 1, true) then
		fail('ui listener events do not carry listener identity/generation')
	end

	local listener = read_file('../src/services/ui/http/listener.lua')
	if not listener:find('opts.events_port', 1, true) then fail('ui http listener does not prefer events_port') end
end

function tests.test_ui_service_starts_listener_from_cfg_ui_not_main_options()
	local s = read_file('../src/services/ui/service.lua')
	if s:find('params%.http[^_%w]') then fail('ui service still reads HTTP config from start params') end
	if s:find('params.verify_login', 1, true) then fail('ui service still reads verifier from start params') end
	if not s:find("{ 'cfg', 'ui' }", 1, true) then fail('ui service does not watch cfg/ui') end
	if not s:find('cap_id = h.cap_id', 1, true) then fail('ui service does not pass configured HTTP capability id') end
	if s:find('start_transport_pump', 1, true) then fail('ui service still starts transport pump') end
end

function tests.test_ui_and_http_do_not_consume_main_legacy_injection_fields()
	for _, root in ipairs({ '../src/services/ui', '../src/services/http' }) do
		for _, path in ipairs(scan_files(root)) do
			local s = read_file(path)
			for _, needle in ipairs({ 'run_http', 'verify_login', 'from_legacy_params', 'params.http_listen', 'opts.http_listen' }) do
				if s:find(needle, 1, true) then fail(path .. ' consumes legacy main field ' .. needle) end
			end
		end
	end
end

function tests.test_read_model_store_has_no_queue_or_mailbox_fanout()
	local s = read_file('../src/services/ui/read_model_store.lua')
	if s:find("devicecode.support.queue", 1, true) then fail('read_model_store depends on queue') end
	if s:find("fibers.mailbox", 1, true) then fail('read_model_store depends on mailbox') end
	if s:find("fibers.perform", 1, true) then fail('read_model_store performs Ops') end
	if s:find("perform_raw", 1, true) then fail('read_model_store uses perform_raw') end
end

function tests.test_read_model_watches_owns_watch_fanout_boundary()
	local s = read_file('../src/services/ui/read_model_watches.lua')
	if not s:find("devicecode.support.queue", 1, true) then fail('read_model_watches does not own queue fanout') end
	if not s:find("fibers.mailbox", 1, true) then fail('read_model_watches does not own bounded watch queues') end
	if not s:find('watch_open', 1, true) then fail('read_model_watches does not expose watch_open') end
end

function tests.test_ui_service_wires_same_store_into_read_model_component()
	local s = read_file('../src/services/ui/service.lua')
	if not s:find('read_model_opts.model = model', 1, true) then
		fail('ui service does not pass service model into read_model.start')
	end
	if not s:find('read_model_opts.watch_owner = watch_owner', 1, true) then
		fail('ui service does not pass watch owner into read_model.start')
	end
end

function tests.test_ui_service_records_component_outcomes_before_policy()
	local s = read_file('../src/services/ui/service.lua')
	if not s:find('record_component_done', 1, true) then fail('ui service does not record component outcomes') end
	if not s:find('classify_service_component_done', 1, true) then fail('ui service component completion does not use supervision classifier') end
end

function tests.test_upload_accepts_only_read_chunk_op_body_boundary()
	local upload = read_file('../src/services/ui/update/upload.lua')
	if upload:find('read_some_op', 1, true) or upload:find('read_op', 1, true) then
		fail('upload accepts non read_chunk_op body compatibility path')
	end
	if not upload:find('request body has no read_chunk_op', 1, true) then fail('upload does not require read_chunk_op') end
end


function tests.test_ui_command_forwarding_is_op_first()
	local request = read_file('../src/services/ui/http/request.lua')
	if not request:find('user_operation.run_op', 1, true) then fail('command forwarding does not use user_operation.run_op') end
	if not request:find('conn:call_op', 1, true) then fail('command forwarding does not use conn:call_op') end
	if request:find('conn:call(', 1, true) then fail('command forwarding still hides blocking conn:call') end

	local user_operation = read_file('../src/services/ui/user_operation.lua')
	if not user_operation:find('spec.run_op', 1, true) then fail('user_operation does not accept op-first specs') end
end

function tests.test_ui_upload_and_user_operation_have_timeout_races()
	local upload = read_file('../src/services/ui/update/upload.lua')
	if not upload:find('upload_timeout', 1, true) then fail('upload timeout option missing') end
	if not upload:find('boolean_choice', 1, true) then fail('upload timeout is not an explicit race') end

	local user_operation = read_file('../src/services/ui/user_operation.lua')
	if not user_operation:find('boolean_choice', 1, true) then fail('user_operation timeout is not an explicit race') end
	if user_operation:find("require 'fibers.mailbox'", 1, true) then fail('user_operation still uses mailbox timeout worker') end
end

function tests.test_http_response_writes_are_op_only()
	local response = read_file('../src/services/ui/http/response.lua')
	if response:find('function Response:reply%(') then fail('response exposes non-op reply') end
	if response:find('function Response:reply_json%(') then fail('response exposes non-op reply_json') end
	if response:find('function Response:reply_error%(') then fail('response exposes non-op reply_error') end
	if not response:find('function Response:abandon_now%(') then fail('response lacks immediate abandon_now') end
	if not response:find('function Response:terminate%(') then fail('response lacks finaliser-safe terminate') end
	if not response:find('write_headers_op', 1, true) then fail('response does not use write_headers_op') end
	if not response:find('write_chunk_op', 1, true) then fail('response does not use write_chunk_op') end

	for _, path in ipairs(scan_files('../src/services/ui')) do
		local src = read_file(path)
		if src:find('owner:reply%(') then fail(path .. ' uses non-op response reply') end
		if src:find('owner:reply_json%(') then fail(path .. ' uses non-op response reply_json') end
		if src:find('owner:reply_error%(') then fail(path .. ' uses non-op response reply_error') end
	end
end

function tests.test_sse_is_request_owned_streaming_http_not_transport_code()
	local s = read_file('../src/services/ui/http/sse.lua')
	if not s:find('watch_open', 1, true) then fail('SSE does not open a read-model watch') end
	if not s:find('text/event%-stream') then fail('SSE does not emit event-stream headers') end
	if s:find('cqueues', 1, true) or s:find('lua_http', 1, true) then fail('SSE mentions backend internals') end
end

function tests.test_artifact_ingest_boundary_has_no_raw_blocking_fallbacks()
	local ingest = read_file('../src/services/ui/update/artifact_ingest.lua')
	for _, raw in ipairs({ 'open_ingest(', ':append(', ':write(', ':commit(', ':abort(', ':close(' }) do
		if ingest:find(raw, 1, true) then fail('artifact_ingest contains raw blocking fallback: ' .. raw) end
	end
	if not ingest:find('open_ingest_op', 1, true) then fail('artifact_ingest lacks open_ingest_op boundary') end
	if not ingest:find('append_chunk_op', 1, true) then fail('artifact_ingest lacks append_chunk_op boundary') end
	if not ingest:find('commit_op', 1, true) then fail('artifact_ingest lacks commit_op boundary') end
	if not ingest:find('abort_now', 1, true) then fail('artifact_ingest lacks abort_now boundary') end
end

function tests.test_read_model_store_declares_first_token_replay_index()
	local store = read_file('../src/services/ui/read_model_store.lua')
	if not store:find('_index_first', 1, true) then fail('read_model_store lacks first-token index') end
	if not store:find('_candidate_keys', 1, true) then fail('read_model_store lacks indexed candidate selection') end
end

function tests.test_ui_service_observes_session_pulse_not_event_sink()
	local service = read_file('../src/services/ui/service.lua')
	local store = read_file('../src/services/ui/sessions.lua')
	if service:find('set_event_sink', 1, true) or store:find('set_event_sink', 1, true) then fail('ui still exposes session event sink') end
	if store:find('event_sink', 1, true) or store:find('on_event', 1, true) then fail('session store still accepts event-sink compatibility options') end
	if not service:find('sessions:changed_op', 1, true) and not service:find('state.sessions:changed_op', 1, true) then
		fail('ui service does not observe session changed_op')
	end
end

function tests.test_read_model_component_uses_scope_aware_never_wait()
	local service = read_file('../src/services/ui/service.lua')
	if service:find('component_scope:not_ok_op()', 1, true) then fail('read-model component waits on its own not_ok_op') end
	if not service:find('fibers.perform(fibers.never())', 1, true) then fail('read-model component does not use never() as long-lived wait') end
end

function tests.test_response_headers_state_is_committed_after_transport_write()
	local response = read_file('../src/services/ui/http/response.lua')
	local guard_pos = response:find('function Response:write_headers_op', 1, true)
	local token_pos = response:find('acquire_start_token', guard_pos, true)
	local state_pos = response:find("self._state = opts.end_stream and 'ended' or 'headers_sent'", guard_pos, true)
	if not token_pos then fail('write_headers_op does not use start token') end
	if not state_pos then fail('write_headers_op does not commit headers_sent after write') end
	if state_pos < token_pos then fail('headers state appears to be committed before start token/write path') end
end

function tests.test_response_headers_op_does_not_mutate_in_guard_path()
	local response = read_file('../src/services/ui/http/response.lua')
	local start_pos = response:find('function Response:write_headers_op', 1, true)
	local end_pos = response:find('function Response:write_chunk_op', start_pos, true)
	local body = response:sub(start_pos, end_pos - 1)
	if body:find('fibers.guard(function', 1, true) then fail('write_headers_op still uses a mutating guard path') end
	if not body:find('acquire_start_token_op', 1, true) then fail('write_headers_op does not use the choice-safe start token op') end
end

function tests.test_ui_service_does_not_retain_ui_projection_state()
	local service = read_file('../src/services/ui/service.lua')
	for _, needle in ipairs({ 'topics.summary()', 'topics.read_model_status()', 'topics.session_count()', "'state', 'ui'" }) do
		if service:find(needle, 1, true) then fail('ui service retains or unretains UI projection state: ' .. needle) end
	end
	if not service:find('self%-ingesting projection loop') then fail('ui service does not document projection feedback boundary') end
end

function tests.test_read_model_declares_self_ingestion_exclusions()
	local topics = read_file('../src/services/ui/topics.lua')
	local read_model = read_file('../src/services/ui/read_model.lua')
	if not topics:find('default_excluded_retained_patterns', 1, true) then fail('ui topics do not declare retained-input exclusions') end
	if not topics:find("t('state', 'ui', '#')", 1, true) then fail('state/ui/# is not excluded') end
	if not topics:find("t('obs', 'v1', 'ui', '#')", 1, true) then fail('obs/v1/ui/# is not excluded') end
	if not read_model:find('should_ingest_event', 1, true) then fail('read model has no retained-feed exclusion check') end
end

return tests
