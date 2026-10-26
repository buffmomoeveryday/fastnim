# expect: htmxSource is not available for htmx 2
import fastnim

discard htmxPlugin(version = 2)
discard initRequest(HttpMethod.Get, "/").htmxSource
