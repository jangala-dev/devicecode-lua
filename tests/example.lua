package.path = "../src/?.lua;" .. package.path
package.path = '../?.lua;../?/init.lua;./?.lua;./?/init.lua;' .. package.path

local function add_path(prefix)
    package.path = prefix .. '?.lua;' .. prefix .. '?/init.lua;' .. package.path
end

local env = os.getenv('DEVICECODE_ENV') or 'dev'
if env == 'prod' then
    add_path('./lib/')
else
    add_path('../vendor/lua-fibers/src/')
    add_path('../vendor/lua-bus/src/')
    add_path('../vendor/lua-trie/src/')
    add_path('./')
end

local fibers = require 'fibers'
local sleep  = require 'fibers.sleep'
local bus    = require 'bus'

local http = require 'services.http'
local blob = require 'devicecode.blob_source'

fibers.run(function ()
  print('[main] creating bus')

  local b = bus.new()

  local service_conn = b:connect({
    origin_base = { kind = 'local', principal = 'http-service' },
  })

  local client_conn = b:connect({
    origin_base = { kind = 'local', principal = 'example-client' },
  })

  print('[main] opening HTTP service handle')

  local svc, err = http.service.open_handle(service_conn, {
    id = 'main',

    config = {
      schema = 'devicecode.config/http/1',
      id = 'main',
      policy = {
        allowed_schemes = { http = true, https = true },
        allowed_hosts = {
          ['httpbin.org'] = true,
          ['postman-echo.com'] = true,
        },
      },
    },
  })

  assert(svc, err)

  local http_ref = http.sdk.new_ref(client_conn, 'main')

  print('[client] sending POST over the bus')
  print('[client] preparing request body capability')

  local body_source = blob.from_string([[{"hello":"from lua over bus"}]])

  local which, result, call_err = fibers.perform(fibers.named_choice({
    post = http_ref:exchange_op({
      method = 'POST',
      uri = 'https://httpbin.org/post',

      headers = {
        ['content-type'] = 'application/json',
        ['accept'] = 'application/json',
      },

      body_source = body_source,
    }),

    timeout = sleep.sleep_op(10):wrap(function ()
      return nil, 'timeout'
    end),
  }))

  if which == 'timeout' then
    print('[client] timed out; request was abandoned and service work cancelled')
    error('POST timed out', 0)
  end

  if not result then
    print('[client] POST failed: ' .. tostring(call_err))
    error(call_err or 'POST failed', 0)
  end

  local response = result.result

  print('[client] HTTP status: ' .. tostring(response.status))

  local status = tonumber(response.status)
  if status and status >= 200 and status < 300 then
    print('[client] POST succeeded')
  else
    error('POST returned non-success status: ' .. tostring(response.status), 0)
  end

  svc:terminate('example complete')
  print('[main] done')
end)
