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
local speech
for _, item in ipairs(menu) do if item.text == "听书" then speech = item end end
equal("function", type(speech and speech.callback), "main menu exposes the reserved speech entry")
speech.callback()
equal("听书功能尚未配置", presented.text, "speech placeholder text is exact")
equal(7, #menu, "speech reservation adds exactly one menu entry")

return count
