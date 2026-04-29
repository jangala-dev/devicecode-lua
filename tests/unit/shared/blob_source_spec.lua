local fibers      = require 'fibers'
local sleep       = require 'fibers.sleep'
local op          = require 'fibers.op'
local runfibers   = require 'tests.support.run_fibers'
local blob_source = require 'shared.blob_source'

local T = {}

function T.string_source_reads_chunks_and_reaches_eof()
  runfibers.run(function()
    local src = blob_source.from_string('abcdef')

    local c1, e1 = fibers.perform(src:read_chunk_op(2))
    assert(c1 == 'ab' and e1 == nil)

    local c2, e2 = fibers.perform(src:read_chunk_op(3))
    assert(c2 == 'cde' and e2 == nil)

    local c3, e3 = fibers.perform(src:read_chunk_op(3))
    assert(c3 == 'f' and e3 == nil)

    local c4, e4 = fibers.perform(src:read_chunk_op(3))
    assert(c4 == nil and e4 == nil)
  end)
end

function T.string_source_rejects_invalid_max_bytes()
  runfibers.run(function()
    local src = blob_source.from_string('abc')
    local chunk, err = fibers.perform(src:read_chunk_op(0))
    assert(chunk == nil)
    assert(tostring(err):match('invalid max_bytes'))
  end)
end

function T.memory_sink_accumulates_written_chunks()
  runfibers.run(function()
    local sink = blob_source.to_memory()
    local ok1, err1 = fibers.perform(sink:write_chunk_op('ab'))
    local ok2, err2 = fibers.perform(sink:write_chunk_op('cd'))
    assert(ok1 == true and err1 == nil)
    assert(ok2 == true and err2 == nil)
    assert(sink:result() == 'abcd')
  end)
end

function T.copy_op_copies_string_source_to_memory_sink()
  runfibers.run(function()
    local src = blob_source.from_string('hello world')
    local sink = blob_source.to_memory()

    local st, rep, bytes = fibers.perform(blob_source.copy_op(src, sink, { chunk_size = 4 }))
    assert(st == 'ok', tostring(bytes or rep))
    assert(bytes == 11)
    assert(sink:result() == 'hello world')
  end)
end

function T.copy_op_does_not_close_when_disabled()
  runfibers.run(function()
    local src_closed = 0
    local sink_closed = 0
    local src = {
      remaining = true,
      read_chunk_op = function(self, n)
        return op.guard(function()
          if self.remaining then
            self.remaining = false
            return op.always('xy', nil)
          end
          return op.always(nil, nil)
        end)
      end,
      close_op = function()
        return op.guard(function()
          src_closed = src_closed + 1
          return op.always(true, nil)
        end)
      end,
    }
    local sink = {
      chunks = {},
      write_chunk_op = function(self, chunk)
        return op.guard(function()
          self.chunks[#self.chunks + 1] = chunk
          return op.always(true, nil)
        end)
      end,
      close_op = function()
        return op.guard(function()
          sink_closed = sink_closed + 1
          return op.always(true, nil)
        end)
      end,
    }

    local st, rep, bytes = fibers.perform(blob_source.copy_op(src, sink, {
      close_source = false,
      close_sink = false,
    }))
    assert(st == 'ok', tostring(bytes or rep))
    assert(bytes == 2)
    assert(src_closed == 0)
    assert(sink_closed == 0)
  end)
end

function T.copy_op_closes_on_timeout_losing_arm()
  runfibers.run(function()
    local src_closed = 0
    local sink_closed = 0
    local src = {
      read_chunk_op = function()
        return sleep.sleep_op(0.2):wrap(function() return 'late', nil end)
      end,
      close_op = function()
        return op.guard(function()
          src_closed = src_closed + 1
          return op.always(true, nil)
        end)
      end,
    }
    local sink = {
      write_chunk_op = function(self, chunk)
        return op.always(true, nil)
      end,
      close_op = function()
        return op.guard(function()
          sink_closed = sink_closed + 1
          return op.always(true, nil)
        end)
      end,
    }

    local which = fibers.perform(fibers.named_choice{
      copy = blob_source.copy_op(src, sink):wrap(function(...) return 'copy', ... end),
      timeout = sleep.sleep_op(0.02):wrap(function() return 'timeout' end),
    })
    assert(which == 'timeout')

    fibers.perform(sleep.sleep_op(0.02))

    assert(src_closed == 1)
    assert(sink_closed == 1)
  end)
end

function T.copy_op_fails_when_sink_write_fails()
  runfibers.run(function()
    local src = blob_source.from_string('boom')
    local sink = {
      write_chunk_op = function(self, chunk)
        return op.always(nil, 'sink failed')
      end,
      close_op = function()
        return op.always(true, nil)
      end,
    }

    local st, rep, primary = fibers.perform(blob_source.copy_op(src, sink))
    assert(st == 'failed')
    assert(tostring(primary):match('sink failed'))
  end)
end

return T
