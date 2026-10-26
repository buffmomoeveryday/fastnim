# expect: htmxPrompt is not available for htmx 4
import fastnim

discard htmxPlugin(version = 4)
discard initRequest(HttpMethod.Get, "/").htmxPrompt
