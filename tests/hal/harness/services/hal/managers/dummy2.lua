local service = require "service"
local op = require "fibers.op"
local sleep = require "fibers.sleep"
local new_msg = require 'bus'.new_msg

local DummyManagement = {}
DummyManagement.__index = DummyManagement

local function new()
    local dummy_management = {}
    return setmetatable(dummy_management, DummyManagement)
end

function DummyManagement:apply_config(config)
    self.test_arg = config.test_arg
end

function DummyManagement:_manager(ctx, conn, device_event_q, capability_info_q)
    conn:publish(
        new_msg(
            { "dummy2", "status" },
            "running"
        )
    )
    while not ctx:err() do
        op.choice(
            sleep.sleep_op(1),
            ctx:done_op()
        ):perform()
    end
end

function DummyManagement:spawn(ctx, conn, device_event_q, capability_info_q)
    self.test_arg = nil
    self.ctx = ctx
    service.spawn_fiber("Dummy Manager", conn, ctx, function (fctx)
        self:_manager(fctx, conn, device_event_q, capability_info_q)
    end)
end

return { new = new }
