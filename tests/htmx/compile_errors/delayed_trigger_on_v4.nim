# expect: not available for htmx 4
import fastnim

discard htmxPlugin(version = 4)
var response = html "<p>Saved</p>"
response.htmxTrigger("saved", after = HtmxTriggerTiming.Settle)
