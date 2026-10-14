## Shared authentication source templates for generated projects.

import std/strutils

proc sessionAuthSource*(excludePaths: openArray[string]): string =
  ## Returns a development-ready session authentication module.
  let exclusions = "@[\"" & excludePaths.join("\", \"") & "\"]"
  """## Session authentication configuration.
## Replace DemoUsers and the in-memory store before deploying.

import std/tables

import fastnim
import fastnim/plugins/auth

type LoginInput* = object
  username*: string
  password*: string

const DemoUsers = {"ada": "s3cret"}.toTable

let sessionStore* = newSessionStore(defaultTtlSeconds = 3600)

proc credentialsValid*(input: LoginInput): bool =
  ## Checks the generated development account in constant time.
  secureCompare(DemoUsers.getOrDefault(input.username, ""), input.password)

proc authentication*(): Plugin =
  ## Protects application pages with an HttpOnly cookie session.
  authPlugin(initAuthOptions(
    schemes = {AuthScheme.Session},
    sessionStore = sessionStore,
    excludePaths = """ & exclusions & """,
  ))
"""

proc jwtAuthSource*(includePaths, excludePaths: openArray[string]): string =
  ## Returns a development-ready JWT authentication module.
  let inclusions = "@[\"" & includePaths.join("\", \"") & "\"]"
  let exclusions = "@[\"" & excludePaths.join("\", \"") & "\"]"
  """## JWT authentication configuration.
## Set JWT_SECRET in production and replace DemoUsers with your user store.

import std/[os, tables]

import fastnim
import fastnim/plugins/auth

type
  LoginInput* = object
    username*: string
    password*: string

  TokenOutput* = object
    token*: string
    expiresIn*: int

const
  DemoUsers = {"ada": "s3cret"}.toTable
  TokenTtlSeconds* = 3600

let JwtSecret* = getEnv(
  "JWT_SECRET", "development-only-change-me-32-bytes"
)

proc credentialsValid*(input: LoginInput): bool =
  ## Checks the generated development account in constant time.
  secureCompare(DemoUsers.getOrDefault(input.username, ""), input.password)

proc issueToken*(subject: string): TokenOutput =
  ## Issues a short-lived HS256 token for an authenticated subject.
  TokenOutput(
    token: issueJwtHs256(subject, JwtSecret, TokenTtlSeconds),
    expiresIn: TokenTtlSeconds,
  )

proc authentication*(): Plugin =
  ## Protects API routes with bearer JWT authentication.
  authPlugin(initAuthOptions(
    schemes = {AuthScheme.Jwt},
    jwtSecrets = @[JwtSecret],
    includePaths = """ & inclusions & """,
    excludePaths = """ & exclusions & """,
  ))
"""
