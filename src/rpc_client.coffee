###
# _portal is added to denote a portal-gun message
# RPCRequestAcknowledgement is to ensure the responder recieved the request
# RPCCallbackResponse is added to support callbacks for methods
#
# params, if containing a callback function, will have that method replaced
# with RPCCallback which should be used to emit callback responses
#
# Child {RPCRequest} -> Parent
#   Parent {RPCRequestAcknowledgement} -> Child
#   Parent {RPCResponse} -> Child
#
# Child {RPCRequest:{params:[RPCCallback]}} -> Parent
#   Parent {RPCRequestAcknowledgement} -> Child
#   Parent {RPCResponse} -> Child
#   Parent {RPCCallbackResponse} -> Child
#   Parent {RPCCallbackResponse} -> Child
#
# Parent {RPCError} -> Child

@typedef {Object} RPCRequest
@property {Boolean} _portal - Must be true
@property {String} id
@property {String} method
@property {Array<*>} params

@typedef {Object} RPCRequestAcknowledgement
@property {Boolean} _portal - Must be true
@property {String} id
@property {Boolean} acknowledge - must be true

@typedef {Object} RPCResponse
@property {Boolean} _portal - Must be true
@property {String} id
@property {*} result
@property {RPCError} error

@typedef {Object} RPCCallback
@property {Boolean} _portal - Must be true
@property {String} callbackId
@property {Boolean} _portalGunCallback - Must be true

@typedef {Object} RPCCallbackResponse
@property {Boolean} _portal - Must be true
@property {String} callbackId
@property {Array<*>} params

@typedef {Object} RPCError
@property {Boolean} _portal - Must be true
@property {Integer} code
@property {String} message
@property {Object} data - optional
###

Promise = window.Promise or require 'promiz'

errors = require './errors'

deferredFactory = ->
  resolve = null
  reject = null
  promise = new Promise (_resolve, _reject) ->
    resolve = _resolve
    reject = _reject
  promise.resolve = resolve
  promise.reject = reject

  return promise

module.exports = class RPCClient
  constructor: ({@postMessage, @timeout}) ->
    @pendingRequests = {}
    @callbackFunctions = {}

  ###
  @param {Object} props
  @param {String} props.method
  @param {Array<*>} [props.params] - Functions are not allowed
  @returns RPCRequest
  ###
  createRPCRequest: do (lastRequestId = 0) ->
    ({method, params}) ->
      for param in params
        if typeof param is 'function'
          throw new Error 'Functions are not allowed. Use RPCCallback instead.'

      lastRequestId += 1
      id = String lastRequestId
      return {_portal: true, id, method, params}

  ###
  @returns RPCCallback
  ###
  createRPCCallback: do (lastCallbackId = 0) ->
    ->
      lastCallbackId += 1
      id = String lastCallbackId
      return {_portal: true, _portalGunCallback: true, callbackId: id}

  ###
  @param {Object} props
  @param {Array<*>} props.params
  @param {String} props.callbackId
  @returns RPCCallbackResponse
  ###
  createRPCCallbackResponse: ({params, callbackId}) ->
    return {_portal: true, callbackId: callbackId, params}

  ###
  @param {Object} props
  @param {String} props.responseId
  @returns RPCRequestAcknowledgement
  ###
  createRPCRequestAcknowledgement: ({requestId}) ->
    return {_portal: true, id: requestId, acknowledge: true}

  ###
  @param {Object} props
  @param {String} props.requestId
  @param {*} [props.result]
  @param {RPCError|Null} [props.error]
  @returns RPCResponse
  ###
  createRPCResponse: ({requestId, result, rPCError}) ->
    result ?= null
    rPCError ?= null
    return {_portal: true, id: requestId, result, error: rPCError}

  ###
  @param {Object} props
  @param {Errpr} [props.error]
  @returns RPCError
  ###
  createRPCError: ({code, data}) ->
    data ?= null
    message = errors.MESSAGES[code]
    return {_portal: true, code, message, data}

  isRPCEntity: (entity) -> entity?._portal
  isRPCRequest: (request) ->
    request?.id? and request.method?
  isRPCCallback: (callback) -> callback?._portalGunCallback
  isRPCResponse: (response) ->
    response?.id and (
      response.result isnt undefined or response.error isnt undefined
    )
  isRPCCallbackResponse: (response) ->
    response?.callbackId? and response.params?
  isRPCRequestAcknowledgement: (ack) -> ack?.acknowledge is true

  ###
  @param {String} method
  @param {Array<*>} [params]
  @returns {Promise}
  ###
  call: (method, reqParams = []) =>
    deferred = deferredFactory()
    params = []

    # replace callback params
    for param in reqParams
      if typeof param is 'function'
        callback = @createRPCCallback param
        @callbackFunctions[callback.callbackId] = param
        params.push callback
      else
        params.push param

    request = @createRPCRequest {method, params}

    @pendingRequests[request.id] = {
      reject: deferred.reject
      resolve: deferred.resolve
      isAcknowledged: false
    }

    try
      @postMessage JSON.stringify(request), '*'
    catch err
      deferred.reject err
      return deferred

    window.setTimeout =>
      unless @pendingRequests[request.id].isAcknowledged
        deferred.reject new Error 'Message Timeout'
    , @timeout

    return deferred

  ###
  @param {RPCResponse} rPCResponse
  ###
  resolveRPCResponse: (rPCResponse) ->
    request = @pendingRequests[rPCResponse.id]
    unless request?
      throw new Error 'Request not found'

    request.isAcknowledged = true

    {result, error} = rPCResponse
    if error?
      request.reject new Error error.message
    else if result?
      request.resolve result
    else
      request.resolve null
    return null

  ###
  @param {RPCRequestAcknowledgement} rPCRequestAcknowledgement
  ###
  resolveRPCRequestAcknowledgement: (rPCRequestAcknowledgement) ->
    request = @pendingRequests[rPCRequestAcknowledgement.id]
    unless request?
      throw new Error 'Request not found'

    request.isAcknowledged = true
    return null

  ###
  @param {RPCCallbackResponse} rPCCallbackResponse
  ###
  resolveRPCCallbackResponse: (rPCCallbackResponse) =>
    callbackFn = @callbackFunctions[rPCCallbackResponse.callbackId]
    unless callbackFn?
      throw new Error 'Callback not found'

    callbackFn.apply null, rPCCallbackResponse.params
    return null
