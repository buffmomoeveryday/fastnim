## OpenAPI and Swagger UI plugin for FastNim applications.

import ../openapi/spec, ../plugin, ../routing/router

proc openApiPlugin*(
    settings = initOpenApiSettings(), name = "openapi", version = "0.1.0"
): Plugin =
  ## Creates a plugin that configures the built-in OpenAPI endpoints.
  initPlugin(
    name,
    version,
    proc(app: Application) =
      app.configureOpenApi(settings),
  )
