local assertx = require("assertions")
local SpeechProvider = require("legado.lib.speech_provider")
local App = require("legado.ui.app")

local count = 0
local function equal(expected, actual, message) count = count + 1; assertx.equal(expected, actual, message) end

local provider = SpeechProvider.new()
equal(false, provider:isAvailable(), "v0.1.0 speech provider is unavailable")
equal(false, provider:speak("text", { voice = "none" }), "speak is a side-effect-free no-op")
equal(false, provider:pause(), "pause is a side-effect-free no-op")
equal(false, provider:resume(), "resume is a side-effect-free no-op")
equal(false, provider:stop(), "stop is a side-effect-free no-op")
equal(0, #provider:getVoices(), "no voices are advertised")

local presented
local app = App.new({ speech_provider = provider, show = function(view) presented = view end })
local menu = app:menuItems()
local speech, speech_count = nil, 0
for _, item in ipairs(menu) do if item.text == "听书" then speech = item; speech_count = speech_count + 1 end end
equal(0, speech_count, "listening entry removed from the plugin menu")
equal(nil, app.openSpeech, "listening placeholder is no longer a public workflow")

return count
