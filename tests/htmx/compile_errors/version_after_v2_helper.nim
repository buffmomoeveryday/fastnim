# expect: conflicts with htmx 2
import fastnim

discard initRequest(HttpMethod.Get, "/").htmxPrompt
discard htmxPlugin(version = 4)
