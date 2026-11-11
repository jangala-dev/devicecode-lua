-- Keeps deliberately red regression specifications out of the default suite. Enable
-- them while implementing the fixes with RUN_GSM_REGRESSION_TESTS=1.

local enabled = os.getenv('RUN_GSM_REGRESSION_TESTS') == '1'

return function(test_fn)
	if enabled then return test_fn end
	return function() end
end
