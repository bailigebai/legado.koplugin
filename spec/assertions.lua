local assertions = {}

function assertions.equal(expected, actual, message)
    if expected ~= actual then
        error((message or "values differ") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual), 2)
    end
end

function assertions.truthy(value, message)
    if not value then
        error(message or "expected a truthy value", 2)
    end
end

function assertions.type(expected, value, message)
    assertions.equal(expected, type(value), message or "unexpected value type")
end

return assertions
