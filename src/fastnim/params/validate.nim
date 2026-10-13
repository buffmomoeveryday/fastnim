## Value-constraint validation with structured 422 field errors.
##
## Typed JSON parsing confirms field *types*, but shops need value
## constraints: non-empty product names, valid email addresses, positive
## quantities, bounded pagination, and allowed order transitions.
##
## Boundary rule: malformed JSON or wrong field types keep the existing
## ``400 {"detail": ...}`` shape failure (see ``parseJsonBody``); only
## value-constraint failures produce ``422`` through this module.
##
## The 422 envelope contains an ``errors`` array. Each error has a stable code,
## human-readable message, and location such as ``["body", "customer", "email"]``.
## Keeping errors as a sequence preserves multiple failures on one field and
## supports nested objects and arrays.
##
## ```nim
## import fastnim
##
## type Product = object
##   name* {.nonEmpty.}: string
##   email* {.email.}: string
##   qty* {.ge: 1, le: 100.}: int
##
## app.post("/products", body = Product, responses = @[(200, Product)]):
##   ok body
## ```

import std/[json, macros, math, options, strutils]

import fastnim/context/http
import fastnim/jsonfields
import fastnim/params/extract

type
  FieldError* = object
    ## One value-constraint failure on a single field.
    location*: seq[string] ## Path below the input source, e.g. ``@["user", "email"]``.
    code*: string ## Stable rule code, e.g. ``"non_empty"`` or ``"email"``.
    message*: string ## Human-readable message for this field.

  ValidationResult* = object
    ## Outcome of validating a decoded JSON body or query values.
    errors*: seq[FieldError] ## One entry per violated constraint.

  ValidationErrorResponse* = object
    ## Interim 422 envelope. Migrates to the unified ``ApiError`` of issue
    ## #9; ``errors`` preserves every failure and its nested location.
    code*: string ## Machine-readable error code, e.g. ``"validation_failed"``.
    message*: string ## Human-readable summary, e.g. ``"validation failed"``.
    errors*: seq[FieldError] ## Constraint failures with source-prefixed locations.

  ValidatedBody*[T] = object
    ## Outcome of ``request.validate``: the parsed body plus its status.
    ## ``value`` is only meaningful when ``ok`` is true.
    ok*: bool ## True when JSON parsing and validation both passed.
    value*: T ## Parsed request body.
    error*: Option[Response] ## 400 shape or 422 validation response when ``ok`` is false.

  StateTransition*[T: enum] = tuple
    ## One permitted transition between two values of the same enum type.
    fromState: T
    toState: T

func field*(error: FieldError): string {.inline, raises: [].} =
  ## Returns the final field or index in an error location, or ``""`` at the root.
  if error.location.len == 0: "" else: error.location[^1]

template nonEmpty*() {.pragma.}
  ## Marks a string model field as required to be non-empty.
  ## Checked by ``validateModel`` using ``checkNonEmpty``.

template email*() {.pragma.}
  ## Marks a string model field as requiring email format.
  ## Checked by ``validateModel`` using ``checkEmail``.

template positive*() {.pragma.}
  ## Marks a numeric model field as requiring a positive value.
  ## Checked by ``validateModel`` using ``checkPositive``.

template minValue*(bound: static[int]) {.pragma.}
  ## Declares an inclusive integer lower bound for a model field.
  ## Checked by ``validateModel`` using ``checkAtLeast``.

template maxValue*(bound: static[int]) {.pragma.}
  ## Declares an inclusive integer upper bound for a model field.
  ## Checked by ``validateModel`` using ``checkAtMost``.

template minLen*(bound: static[Natural]) {.pragma.}
  ## Declares an inclusive minimum length for a string, sequence, or array field.

template maxLen*(bound: static[Natural]) {.pragma.}
  ## Declares an inclusive maximum length for a string, sequence, or array field.

template gt*(bound: static[SomeNumber]) {.pragma.}
  ## Declares an exclusive numeric lower bound for a model field.

template ge*(bound: static[SomeNumber]) {.pragma.}
  ## Declares an inclusive numeric lower bound for a model field.

template lt*(bound: static[SomeNumber]) {.pragma.}
  ## Declares an exclusive numeric upper bound for a model field.

template le*(bound: static[SomeNumber]) {.pragma.}
  ## Declares an inclusive numeric upper bound for a model field.

macro transitions*(stateType: typedesc, body: untyped): untyped =
  ## Builds a type-checked array of allowed enum transitions.
  ##
  ## ```nim
  ## const AllowedTransitions = transitions(OrderState):
  ##   OrderState.pending.to OrderState.paid
  ##   OrderState.paid.to OrderState.shipped
  ## ```
  let statements =
    if body.kind == nnkStmtList: body
    else: newStmtList(body)
  if statements.len == 0:
    error("transitions requires at least one 'fromState.to toState' entry", body)

  result = newNimNode(nnkBracket)
  for statement in statements:
    if statement.kind != nnkCommand or statement.len != 2 or
        statement[0].kind != nnkDotExpr or statement[0].len != 2 or
        not eqIdent(statement[0][1], "to"):
      error("expected an enum transition in the form 'fromState.to toState'", statement)

    let transition = newTree(
      nnkTupleConstr,
      newTree(nnkExprColonExpr, ident("fromState"), statement[0][0]),
      newTree(nnkExprColonExpr, ident("toState"), statement[1]),
    )
    result.add(
      newCall(
        newTree(
          nnkBracketExpr,
          bindSym("StateTransition"),
          stateType.copyNimTree(),
        ),
        transition,
      )
    )

proc initValidationResult*(): ValidationResult {.inline, raises: [].} =
  ## Creates an empty (valid) validation result.
  ValidationResult(errors: @[])

proc addError*(
    result: var ValidationResult,
    location: openArray[string],
    code, message: string,
) {.raises: [].} =
  ## Records one error at ``location``.
  result.errors.add(
    FieldError(location: @location, code: code, message: message)
  )

proc addError*(
    result: var ValidationResult, field, code, message: string
) {.raises: [].} =
  ## Records one field error and marks ``result`` as invalid.
  result.addError([field], code, message)

proc isValid*(validation: ValidationResult): bool {.inline, raises: [].} =
  ## Returns whether ``result`` holds no field errors.
  validation.errors.len == 0

proc mergeErrors*(
    result: var ValidationResult, other: ValidationResult
) {.raises: [].} =
  ## Folds ``other`` into ``result``. Used to combine per-section checks.
  for error in other.errors:
    result.errors.add(error)

proc withPrefix*(
    validation: ValidationResult, prefix: openArray[string]
): ValidationResult {.raises: [].} =
  ## Returns ``validation`` with ``prefix`` prepended to every error location.
  result = initValidationResult()
  for error in validation.errors:
    result.addError(@prefix & error.location, error.code, error.message)

proc checkNonEmpty*(
    result: var ValidationResult, field, value: string
) {.raises: [].} =
  ## Records ``"non_empty"`` on ``field`` when ``value`` is empty.
  ## Use for JSON body string fields such as product names.
  if value.len == 0:
    result.addError(field, "non_empty", "must not be empty")

proc isEmailFormat*(value: string): bool {.inline, raises: [].} =
  ## Returns whether ``value`` looks like an email address.
  ##
  ## The check is intentionally simple (one ``@``, non-empty local part,
  ## dotted domain without empty labels or spaces) rather than
  ## RFC-complete; use a dedicated mail library when exactness matters.
  let parts = value.split('@')
  if parts.len != 2:
    return false
  if parts[0].len == 0 or parts[1].len == 0:
    return false
  if ' ' in value:
    return false
  let domain = parts[1]
  if '.' notin domain or domain[0] == '.' or domain[^1] == '.':
    return false
  for label in domain.split('.'):
    if label.len == 0:
      return false
  true

proc checkEmail*(
    result: var ValidationResult, field, value: string
) {.raises: [].} =
  ## Records ``"email"`` on ``field`` when ``value`` is not email-shaped.
  ## Use for JSON body string fields such as contact addresses.
  if not isEmailFormat(value):
    result.addError(field, "email", "must be a valid email address")

proc checkPositive*[T](
    result: var ValidationResult, field: string, value: T
) {.raises: [].} =
  ## Records ``"positive"`` on ``field`` when ``value`` is not above zero.
  ## Use for JSON body numeric fields such as prices and quantities.
  when T is SomeNumber:
    if not value.isFiniteNumber():
      result.addFiniteNumberError([field])
    elif value <= 0:
      result.addError(field, "positive", "must be positive")
  else:
    {.error: "checkPositive requires a numeric value".}

proc checkLengthAtLeast*[T](
    result: var ValidationResult,
    location: openArray[string],
    value: T,
    bound: Natural,
) {.raises: [].} =
  ## Records ``"min_length"`` when ``value`` has fewer than ``bound`` items.
  when compiles(value.len):
    if value.len < bound:
      const unit = when T is string: "character" else: "item"
      let units = if bound == 1: unit else: unit & "s"
      result.addError(
        location, "min_length", "must contain at least " & $bound & " " & units
      )
  else:
    {.error: "checkLengthAtLeast requires a value with a length".}

proc checkLengthAtMost*[T](
    result: var ValidationResult,
    location: openArray[string],
    value: T,
    bound: Natural,
) {.raises: [].} =
  ## Records ``"max_length"`` when ``value`` has more than ``bound`` items.
  when compiles(value.len):
    if value.len > bound:
      const unit = when T is string: "character" else: "item"
      let units = if bound == 1: unit else: unit & "s"
      result.addError(
        location, "max_length", "must contain at most " & $bound & " " & units
      )
  else:
    {.error: "checkLengthAtMost requires a value with a length".}

func isFiniteNumber[T](value: T): bool {.inline, raises: [].} =
  when T is SomeFloat:
    classify(value) notin {fcNan, fcInf, fcNegInf}
  else:
    true

func compareIntegerToFloat[T: SomeInteger, U: SomeFloat](
    value: T, bound: U
): int {.raises: [].} =
  let numericBound = BiggestFloat(bound)
  when T is SomeSignedInt:
    if numericBound < BiggestFloat(low(T)):
      return 1
    if numericBound >= -BiggestFloat(low(T)):
      return -1
    let integralBound = BiggestInt(floor(numericBound))
    result = cmp(BiggestInt(value), integralBound)
    if result == 0 and numericBound != BiggestFloat(integralBound):
      result = -1
  else:
    if numericBound < 0:
      return 1
    if numericBound >= -BiggestFloat(low(int64)) * 2:
      return -1
    let integralBound = BiggestUInt(floor(numericBound))
    result = cmp(BiggestUInt(value), integralBound)
    if result == 0 and numericBound != BiggestFloat(integralBound):
      result = -1

func compareNumbers[T: SomeNumber, U: SomeNumber](
    value: T, bound: U
): int {.raises: [].} =
  when T is SomeSignedInt and U is SomeSignedInt:
    cmp(BiggestInt(value), BiggestInt(bound))
  elif T is SomeUnsignedInt and U is SomeUnsignedInt:
    cmp(BiggestUInt(value), BiggestUInt(bound))
  elif T is SomeSignedInt and U is SomeUnsignedInt:
    if value < 0: -1 else: cmp(BiggestUInt(value), BiggestUInt(bound))
  elif T is SomeUnsignedInt and U is SomeSignedInt:
    if bound < 0: 1 else: cmp(BiggestUInt(value), BiggestUInt(bound))
  elif T is SomeInteger and U is SomeFloat:
    compareIntegerToFloat(value, bound)
  elif T is SomeFloat and U is SomeInteger:
    -compareIntegerToFloat(bound, value)
  else:
    cmp(BiggestFloat(value), BiggestFloat(bound))

proc addFiniteNumberError(
    result: var ValidationResult, location: openArray[string]
) {.raises: [].} =
  result.addError(location, "finite_number", "must be a finite number")

proc checkGreaterThan*[T, U](
    result: var ValidationResult,
    location: openArray[string],
    value: T,
    bound: U,
) {.raises: [].} =
  ## Records ``"greater_than"`` when ``value`` is not greater than ``bound``.
  when T is SomeNumber and U is SomeNumber:
    if not value.isFiniteNumber():
      result.addFiniteNumberError(location)
    elif compareNumbers(value, bound) <= 0:
      result.addError(location, "greater_than", "must be greater than " & $bound)
  else:
    {.error: "checkGreaterThan requires numeric values".}

proc checkGreaterOrEqual*[T, U](
    result: var ValidationResult,
    location: openArray[string],
    value: T,
    bound: U,
) {.raises: [].} =
  ## Records ``"greater_than_or_equal"`` when ``value`` is below ``bound``.
  when T is SomeNumber and U is SomeNumber:
    if not value.isFiniteNumber():
      result.addFiniteNumberError(location)
    elif compareNumbers(value, bound) < 0:
      result.addError(
        location, "greater_than_or_equal",
        "must be greater than or equal to " & $bound,
      )
  else:
    {.error: "checkGreaterOrEqual requires numeric values".}

proc checkLessThan*[T, U](
    result: var ValidationResult,
    location: openArray[string],
    value: T,
    bound: U,
) {.raises: [].} =
  ## Records ``"less_than"`` when ``value`` is not less than ``bound``.
  when T is SomeNumber and U is SomeNumber:
    if not value.isFiniteNumber():
      result.addFiniteNumberError(location)
    elif compareNumbers(value, bound) >= 0:
      result.addError(location, "less_than", "must be less than " & $bound)
  else:
    {.error: "checkLessThan requires numeric values".}

proc checkLessOrEqual*[T, U](
    result: var ValidationResult,
    location: openArray[string],
    value: T,
    bound: U,
) {.raises: [].} =
  ## Records ``"less_than_or_equal"`` when ``value`` is above ``bound``.
  when T is SomeNumber and U is SomeNumber:
    if not value.isFiniteNumber():
      result.addFiniteNumberError(location)
    elif compareNumbers(value, bound) > 0:
      result.addError(
        location, "less_than_or_equal", "must be less than or equal to " & $bound
      )
  else:
    {.error: "checkLessOrEqual requires numeric values".}

proc checkAtLeast*[T](
    result: var ValidationResult, field: string, value, bound: T
) {.raises: [].} =
  ## Records ``"out_of_range"`` on ``field`` when ``value`` is below ``bound``.
  ## Use for lower bounds on JSON body or query values.
  if value < bound:
    result.addError(field, "out_of_range", "must be at least " & $bound)

proc checkAtMost*[T](
    result: var ValidationResult, field: string, value, bound: T
) {.raises: [].} =
  ## Records ``"out_of_range"`` on ``field`` when ``value`` is above ``bound``.
  ## Use for upper bounds on JSON body or query values.
  if value > bound:
    result.addError(field, "out_of_range", "must be at most " & $bound)

proc checkRange*[T](
    result: var ValidationResult, field: string, value, lower, upper: T
) {.raises: [].} =
  ## Records ``"out_of_range"`` on ``field`` when ``value`` is outside
  ## ``lower``..``upper`` (inclusive). Use for bounded JSON body or query
  ## values such as quantities or pagination limits.
  if value < lower or value > upper:
    result.addError(
      field, "out_of_range", "must be between " & $lower & " and " & $upper
    )

proc checkAllowed*[T](
    result: var ValidationResult,
    field: string,
    value: T,
    allowed: openArray[T],
) {.raises: [].} =
  ## Records ``"not_allowed"`` on ``field`` when ``value`` is not in
  ## ``allowed``. Comparison is exact (case-sensitive for strings). Use for
  ## enum-style JSON body or query values such as sort orders.
  if value notin allowed:
    result.addError(field, "not_allowed", "is not an allowed value")

proc checkTransition*[T](
    result: var ValidationResult,
    field: string,
    fromState, toState: T,
    allowed: openArray[(T, T)],
) {.raises: [].} =
  ## Records ``"invalid_transition"`` on ``field`` when the
  ## ``(fromState, toState)`` pair is not in ``allowed``. Use for order
  ## status transitions supplied in a JSON body, e.g. ``pending`` to
  ## ``paid`` but never ``pending`` to ``shipped``.
  if (fromState, toState) notin allowed:
    result.addError(
      field,
      "invalid_transition",
      "transition from '" & $fromState & "' to '" & $toState &
        "' is not allowed",
    )

proc validatePagination*(
    page, limit: int, maxLimit = 100
): ValidationResult {.raises: [].} =
  ## Validates decoded query pagination values: ``page`` must be at least
  ## 1 and ``limit`` must fall within 1..``maxLimit``.
  result = initValidationResult()
  if page < 1:
    result.addError("page", "out_of_range", "must be at least 1")
  if limit < 1:
    result.addError("limit", "out_of_range", "must be at least 1")
  elif limit > maxLimit:
    result.addError("limit", "out_of_range", "must be at most " & $maxLimit)

proc toValidationError*(
    validation: ValidationResult,
    code = "validation_failed",
    message = "validation failed",
    source = "body",
): ValidationErrorResponse {.raises: [].} =
  ## Builds the standard 422 envelope and prefixes locations with ``source``.
  let prefix = if source.len == 0: @[] else: @[source]
  ValidationErrorResponse(
    code: code, message: message, errors: validation.withPrefix(prefix).errors
  )

proc validationResponse*(
    validation: ValidationResult,
    code = "validation_failed",
    message = "validation failed",
    source = "body",
): Response =
  ## Creates the standard 422 response for ``result``.
  ##
  ## The body is assembled directly to keep the wire representation stable.
  let envelope = toValidationError(validation, code, message, source)
  var errors = newJArray()
  for issue in envelope.errors:
    errors.add(
      %*{
        "location": issue.location,
        "code": issue.code,
        "message": issue.message,
      }
    )
  var node = %*{
    "code": envelope.code,
    "message": envelope.message,
    "errors": errors,
  }
  json(statusUnprocessableContent, node)

proc parseAndValidateBody*[T](
    request: Request,
    value: var T,
    validate: proc(value: T): ValidationResult {.closure, raises: [CatchableError].},
): tuple[ok: bool, error: Option[Response]] =
  ## Decodes a JSON request body into ``value`` and runs ``validate`` on it.
  ##
  ## Returns ``(true, none)`` when both steps pass. A JSON shape failure
  ## (malformed JSON or wrong field types) returns the existing 400
  ## ``{"detail": ...}`` response; a value-constraint failure returns the
  ## standard 422 response. Handlers early-return on ``error``:
  ##
  ## ```nim
  ## let checked = parseAndValidateBody(request, body, validateProduct)
  ## if not checked.ok:
  ##   return checked.error.get()
  ## ```
  if not parseJsonBody(request, value):
    return (false, some(json(statusBadRequest, %*{"detail": "invalid JSON request body"})))
  let validation = validate(value)
  if not validation.isValid():
    return (false, some(validationResponse(validation)))
  (true, none(Response))

template effectiveValidationName(
    field: untyped, defaultName: static[string]
): string =
  when field.hasCustomPragma(jsonName):
    const customName = field.getCustomPragmaVal(jsonName).name
    when customName.len == 0:
      {.error: "jsonName cannot be empty".}
    customName
  else:
    defaultName

proc validateValue[T](
    value: T,
    validationResult: var ValidationResult,
    location: seq[string],
) {.raises: [].} =
  when T is Option:
    if value.isSome():
      validateValue(value.get(), validationResult, location)
  elif T is ref:
    if not value.isNil:
      validateValue(value[], validationResult, location)
  elif T is object:
    for validationName, validationField in fieldPairs(value):
      const validationFieldName = effectiveValidationName(
        validationField, validationName
      )
      let validationLocation = location & @[validationFieldName]
      when validationField is SomeFloat and
          (validationField.hasCustomPragma(positive) or
          validationField.hasCustomPragma(gt) or
          validationField.hasCustomPragma(ge) or
          validationField.hasCustomPragma(lt) or
          validationField.hasCustomPragma(le)):
        let validationFieldIsFinite = validationField.isFiniteNumber()
        if not validationFieldIsFinite:
          validationResult.addFiniteNumberError(validationLocation)
      when validationField.hasCustomPragma(nonEmpty):
        when validationField is string:
          if validationField.len == 0:
            validationResult.addError(
              validationLocation, "non_empty", "must not be empty"
            )
        else:
          {.error: "nonEmpty requires a string field".}
      when validationField.hasCustomPragma(email):
        when validationField is string:
          if not isEmailFormat(validationField):
            validationResult.addError(
              validationLocation, "email", "must be a valid email address"
            )
        else:
          {.error: "email requires a string field".}
      when validationField.hasCustomPragma(positive):
        when validationField is SomeNumber:
          when validationField is SomeFloat:
            let validationCanCheckPositive = validationFieldIsFinite
          else:
            const validationCanCheckPositive = true
          if validationCanCheckPositive and validationField <= 0:
            validationResult.addError(
              validationLocation, "positive", "must be positive"
            )
        else:
          {.error: "positive requires a numeric field".}
      when validationField.hasCustomPragma(minValue):
        when validationField is SomeInteger:
          const validationLower =
            validationField.getCustomPragmaVal(minValue).bound
          if validationField < validationLower:
            validationResult.addError(
              validationLocation, "out_of_range",
              "must be at least " & $validationLower,
            )
        else:
          {.error: "minValue requires an integer field".}
      when validationField.hasCustomPragma(maxValue):
        when validationField is SomeInteger:
          const validationUpper =
            validationField.getCustomPragmaVal(maxValue).bound
          if validationField > validationUpper:
            validationResult.addError(
              validationLocation, "out_of_range",
              "must be at most " & $validationUpper,
            )
        else:
          {.error: "maxValue requires an integer field".}
      when validationField.hasCustomPragma(minLen):
        when validationField is string or validationField is seq or
            validationField is array:
          const validationMinimumLength =
            validationField.getCustomPragmaVal(minLen).bound
          checkLengthAtLeast(
            validationResult, validationLocation, validationField,
            validationMinimumLength,
          )
        else:
          {.error: "minLen requires a string, sequence, or array field".}
      when validationField.hasCustomPragma(maxLen):
        when validationField is string or validationField is seq or
            validationField is array:
          const validationMaximumLength =
            validationField.getCustomPragmaVal(maxLen).bound
          checkLengthAtMost(
            validationResult, validationLocation, validationField,
            validationMaximumLength,
          )
        else:
          {.error: "maxLen requires a string, sequence, or array field".}
      when validationField.hasCustomPragma(gt):
        when validationField is SomeNumber:
          const validationExclusiveMinimum =
            validationField.getCustomPragmaVal(gt).bound
          when validationField is SomeFloat:
            if validationFieldIsFinite:
              checkGreaterThan(
                validationResult, validationLocation, validationField,
                validationExclusiveMinimum,
              )
          else:
            checkGreaterThan(
              validationResult, validationLocation, validationField,
              validationExclusiveMinimum,
            )
        else:
          {.error: "gt requires a numeric field".}
      when validationField.hasCustomPragma(ge):
        when validationField is SomeNumber:
          const validationMinimum = validationField.getCustomPragmaVal(ge).bound
          when validationField is SomeFloat:
            if validationFieldIsFinite:
              checkGreaterOrEqual(
                validationResult, validationLocation, validationField,
                validationMinimum,
              )
          else:
            checkGreaterOrEqual(
              validationResult, validationLocation, validationField,
              validationMinimum,
            )
        else:
          {.error: "ge requires a numeric field".}
      when validationField.hasCustomPragma(lt):
        when validationField is SomeNumber:
          const validationExclusiveMaximum =
            validationField.getCustomPragmaVal(lt).bound
          when validationField is SomeFloat:
            if validationFieldIsFinite:
              checkLessThan(
                validationResult, validationLocation, validationField,
                validationExclusiveMaximum,
              )
          else:
            checkLessThan(
              validationResult, validationLocation, validationField,
              validationExclusiveMaximum,
            )
        else:
          {.error: "lt requires a numeric field".}
      when validationField.hasCustomPragma(le):
        when validationField is SomeNumber:
          const validationMaximum = validationField.getCustomPragmaVal(le).bound
          when validationField is SomeFloat:
            if validationFieldIsFinite:
              checkLessOrEqual(
                validationResult, validationLocation, validationField,
                validationMaximum,
              )
          else:
            checkLessOrEqual(
              validationResult, validationLocation, validationField,
              validationMaximum,
            )
        else:
          {.error: "le requires a numeric field".}
      when validationField is ref or validationField is object or
          validationField is seq or
          validationField is array:
        validateValue(validationField, validationResult, validationLocation)
  elif T is seq or T is array:
    for validationIndex, validationItem in value:
      validateValue(
        validationItem, validationResult, location & @[$validationIndex]
      )

template validateModel*[T](value: T): ValidationResult =
  ## Validates ``value`` recursively against its field pragmas.
  ##
  ## Error locations honor ``jsonName`` and include nested object fields and
  ## sequence indexes. Supported constraints are ``nonEmpty``, ``email``,
  ## ``positive``, ``minValue``, ``maxValue``, ``minLen``, ``maxLen``, ``gt``,
  ## ``ge``, ``lt``, and ``le``. Incompatible field types fail at compile time.
  block:
    when T is object:
      var validationResult = initValidationResult()
      validateValue(value, validationResult, newSeq[string]())
      validationResult
    else:
      {.error: "validateModel requires an object value".}

proc modelValidator[T](value: T): ValidationResult =
  ## Adapts the ``validateModel`` template to a validator callback.
  validateModel(value)

proc validate*[T](
    request: Request,
    model: typedesc[T],
    validator: proc(value: T): ValidationResult {.closure, raises: [CatchableError].},
): ValidatedBody[T] =
  ## Decodes the JSON request body as ``T`` and runs ``validator`` on it.
  ##
  ## Returns the parsed ``value`` with ``ok == true`` when both steps pass.
  ## A JSON shape failure (malformed JSON or wrong field types) sets
  ## ``error`` to the existing 400 response; a value-constraint failure sets
  ## it to the standard 422 response. Handlers early-return on ``error``:
  ##
  ## ```nim
  ## app.post("/orders"):
  ##   let checked = request.validate(StatusChange, validateStatusChange)
  ##   if not checked.ok:
  ##     return checked.error.get()
  ##   json(%*{"toStatus": checked.value.toStatus})
  ## ```
  let checked = parseAndValidateBody(request, result.value, validator)
  result.ok = checked.ok
  result.error = checked.error

proc validate*[T](request: Request, model: typedesc[T]): ValidatedBody[T] =
  ## Decodes the JSON request body as ``T`` and validates it with
  ## ``validateModel``, so pragma-annotated models need no validator
  ## argument. Shape failures behave exactly as in ``parseAndValidateBody``.
  ##
  ## ```nim
  ## app.post("/products"):
  ##   let checked = request.validate(CreateProduct)
  ##   if not checked.ok:
  ##     return checked.error.get()
  ##   created Product(name: checked.value.name)
  ## ```
  ##
  ## Inside typed routes (``body = CreateProduct``) the body is already
  ## parsed for you; validate it directly instead of re-parsing:
  ##
  ## ```nim
  ## app.post("/products", body = CreateProduct, responses = @[(201, Product)]):
  ##   let validation = validateModel(body)
  ##   if not validation.isValid():
  ##     return validationResponse(validation)
  ##   created Product(name: body.name)
  ## ```
  validate(request, model, modelValidator[T])
