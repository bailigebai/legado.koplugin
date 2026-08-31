local SpeechProvider = {}
SpeechProvider.__index = SpeechProvider

function SpeechProvider.new()
    return setmetatable({}, SpeechProvider)
end

function SpeechProvider:isAvailable() return false end
function SpeechProvider:speak() return false end
function SpeechProvider:pause() return false end
function SpeechProvider:resume() return false end
function SpeechProvider:stop() return false end
function SpeechProvider:getVoices() return {} end

return SpeechProvider
