Promise = window.Promise or require 'promiz'

RPCClient = require './rpc_client'
errors = require './errors'

IS_FRAMED = window.self isnt window.top

isValidOrigin = (origin, trusted, allowSubdomains) ->
  unless trusted?
    return true

  for trust in trusted
    regex = if allowSubdomains
      new RegExp \
        "^https?://(\\w+\\.)?(\\w+\\.)?#{trust.replace(/\./g, '\\.')}/?$"
    else
      new RegExp "^https?://#{trust.replace(/\./g, '\\.')}/?$"

    if regex.test origin
      return true

  return false

class PortalGun
  ###
  # Bind global message event listener
  @param {Object} config
  @param {Number} config.timeout - request timeout (ms)
  @param {Array<String>|Null} config.trusted - trusted domains e.g.['clay.io']
  @param {Boolean} config.allowSubdomains - trust subdomains of trusted domain
  ###
  constructor: ({timeout, @trusted, @allowSubdomains} = {}) ->
    timeout ?= null
    @trusted ?= null
    @allowSubdomains ?= false
    @isListening = false
    @client = new RPCClient({
      timeout: timeout
      postMessage: (msg, origin) ->
        window.parent?.postMessage msg, origin
    })
    # All parents must respond to 'ping' with 'pong'
    @registeredMethods = {
      ping: -> 'pong'
    }

  listen: =>
    @isListening = true
    window.addEventListener 'message', @onMessage
    @validation = @client.call 'ping'

  ###
  @param {String} method
  @param {*} params - Arrays will be deconstructed as multiple args
  ###
  call: (method, params = []) =>
    unless @isListening
      return new Promise (resolve, reject) ->
        reject new Error 'Must call listen() before call()'

    # params should always be an array
    unless Object::toString.call(params) is '[object Array]'
      params = [params]

    localMethod = (method, params) =>
      fn = @registeredMethods[method]
      unless fn
        throw new Error 'Method not found'
      return fn.apply null, params

    if IS_FRAMED
      frameError = null
      @validation
      .then =>
        @client.call method, params
      .catch (err) ->
        frameError = err
        return localMethod method, params
      .catch (err) ->
        if err.message is 'Method not found' and frameError isnt null
          throw frameError
        else
          throw err
    else
      new Promise (resolve) ->
        resolve localMethod(method, params)

  onMessage: (e) =>
    reply = (message) ->
      e.source.postMessage JSON.stringify(message), '*'

    try # silent
      message = if typeof e.data is 'string' then JSON.parse(e.data) else e.data

      unless @client.isRPCEntity message
        throw new Error 'Non-portal message'

      if @client.isRPCRequest message
        method = message.method
        reqParams = message.params or []
        params = []

        # replace callback params with proxy functions
        for param in reqParams
          if @client.isRPCCallback param
            do (param) =>
              params.push (args...) =>
                reply @client.createRPCCallbackResponse {
                  params: args
                  callbackId: param.callbackId
                }
          else
            params.push param

        # acknowledge request, prevent request timeout
        reply @client.createRPCRequestAcknowledgement {requestId: message.id}

        @call method, params
        .then (result) =>
          reply @client.createRPCResponse {
            requestId: message.id
            result: result
          }
        .catch (err) =>
          reply @client.createRPCResponse {
            requestId: message.id
            rPCError: @client.createRPCError {
              code: errors.CODES.DEFAULT
            }
          }
      else if @client.isRPCEntity message
        if isValidOrigin e.origin, @trusted, @allowSubdomains
          @client.resolve message
        else if @client.isRPCResponse message
          @client.resolve @client.createRPCResponse {
            requestId: message.id
            rPCError: @client.createRPCError {
              code: errors.CODES.INVALID_ORIGIN
            }
          }
        else
          # FIXME
          throw new Error 'invalid origin'
      else
        throw new Error 'Unknown RPCEntity type'
    catch err
      return

  ###
  # Register method to be called on child request, or local request fallback

  @param {String} method
  @param {Function} fn
  ###
  on: (method, fn) =>
    @registeredMethods[method] = fn

module.exports = PortalGun
