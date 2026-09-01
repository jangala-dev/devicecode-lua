local indentation = require 'tools.lua_indentation'

local T = {}

local function eq(got, expected)
	assert(got == expected, ('expected %s, got %s'):format(tostring(expected), tostring(got)))
end

function T.accepts_tabs_and_alignment_spaces()
	local content = table.concat({
		'local function example()',
		'\tlocal value = {',
		'\t\tkey = true,',
		'\t}',
		'\t  return value',
		'end',
	}, '\n')

	eq(#indentation.check_content(content), 0)
end

function T.ignores_multiline_string_and_comment_payloads()
	local content = table.concat({
		'local json = [=[',
		'    { "nested": true }',
		'  ]=]',
		'--[==[',
		'    comment payload',
		' ]==]',
		'local quoted = "continued\\',
		'    string"',
		'\treturn json .. quoted',
	}, '\n')

	eq(#indentation.check_content(content), 0)
end

function T.rejects_space_indentation_and_space_before_tab()
	local content = table.concat({
		'local function example()',
		'    local first = true',
		'\t \tlocal second = true',
		'end',
	}, '\n')
	local violations = indentation.check_content(content)

	eq(#violations, 2)
	eq(violations[1].line, 2)
	eq(violations[2].line, 3)
end

return T
