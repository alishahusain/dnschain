###

dnschain
http://dnschain.org

Copyright (c) 2014 okTurtles Foundation

This Source Code Form is subject to the terms of the Mozilla Public
License, v. 2.0. If a copy of the MPL was not distributed with this
file, You can obtain one at http://mozilla.org/MPL/2.0/.

###

###
This file contains the logic to handle connections on port 443
These connections can be naked HTTPS or wrapped inside of TLS
###

###
NOTE: There can be any number of EncryptedServers. A good example of that is when running the tests.
The TLSServers are shared between EncryptedServers.

            __________________________        ________________________
443 traffic |                        |   *--->|      TLSServer       |     ______________
----------->|     EncryptedServer    |--*     | (Dumb decrypter)     |---->| HTTPServer |----> Multiple destinations
            |(Categorization/Routing)|   *    | (One of many)        |     ______________
            __________________________    *   | (Unique destination) |
                                           *  _______________________|
                                            *    _____________   Soon
                                             *-->| TLSServer |----------> Unblock (Vastly simplified)
                                                 _____________
###

module.exports = (dnschain) ->
    # expose these into our namespace
    for k of dnschain.globals
        eval "var #{k} = dnschain.globals.#{k};"

    libHTTPS = new ((require "./httpsUtils")(dnschain)) # TODO: httpsUtils doesn't need to be a class
    pem = (require './pem')(dnschain)
    httpSettings = gConf.get "http"
    unblockSettings = gConf.get "unblock"
    tlsLog = gNewLogger "TLSServer"

    httpsVars = tls: Promise.resolve()

    keyMaterial = _(httpSettings).pick(['tlsKey', 'tlsCert']).transform((o, v, k)->
        o[k] = { key:k, path:v, exists: fs.existsSync(v) }
    ).value()

    # Auto-generate public/private key pair if they don't exist
    if _.some(keyMaterial, exists:false)
        missing = _.find(keyMaterial, exists:false)
        tlsLog.warn "File for http:#{missing.key} does not exist: #{missing.path}".bold.red
        tlsLog.warn "Vist this link for information on how to generate this file:".bold
        tlsLog.warn "https://github.com/okTurtles/dnschain/blob/master/docs/How-do-I-run-my-own.md#getting-started".bold

        # In the case where one file exists but the other does not
        # we do not auto-generate them for the user (so as to not overwrite anything)      
        if exists = _.find(keyMaterial, exists:true)
            tlsLog.error "\nhttp:#{exists.key} exists at:\n\t".bold.yellow, exists.path.bold, "\nbut http:#{missing.key} does not exist at:\n\t".bold.red, missing.path.bold
            gErr "Missing file for http:#{missing.key}"

        tlsLog.warn "Auto-generating private key and certificate for you...".bold.yellow
        
        {tlsKey, tlsCert} = gConf.chains.dnschain.stores.defaults.get('http')
        unless httpSettings.tlsKey is tlsKey and httpSettings.tlsCert is tlsCert
            msg = "Can't autogen keys for you because you've customized their paths"
            if process.env.TEST_DNSCHAIN
                tlsLog.warn "Test detected. Not throwing error:".bold, msg.bold.yellow
            else
                gErr msg
        [tlsKey, tlsCert] = [httpSettings.tlsKey, httpSettings.tlsCert]
        httpsVars.tls = pem.genKeyCertPair(tlsKey, tlsCert).then ->
            tlsLog.info "Successfully autogenerated", {key:tlsKey, cert:tlsCert}

    # Fetch the public key fingerprint of the cert we're using and log to console 
    httpsVars.tls = httpsVars.tls.then ->
        httpsVars.tlsOptions =
            key: fs.readFileSync httpSettings.tlsKey
            cert: fs.readFileSync httpSettings.tlsCert

        pem.certFingerprint(httpSettings.tlsCert).then (f) ->
            httpsVars.fingerprint = f
            tlsLog.info "Your certificate fingerprint is:", f.bold

    class EncryptedServer
        constructor: (@dnschain) ->
            @log = gNewLogger "HTTPS"
            @log.debug gLineInfo "Loading HTTPS..."
            @rateLimiting = gConf.get 'rateLimiting:https'

            @server = net.createServer (c) =>
                key = "https-#{c.remoteAddress}"
                limiter = gThrottle key, => new Bottleneck @rateLimiting.maxConcurrent, @rateLimiting.minTime, @rateLimiting.highWater, @rateLimiting.strategy
                limiter.submit (@callback.bind @), c, null
            @server.on "error", (err) -> gErr err
            @server.on "close", => @log.info "HTTPS server received close event."
            gFillWithRunningChecks @

        start: ->
            @startCheck (cb) =>
                listen = =>
                    @server.listen httpSettings.tlsPort, httpSettings.host, =>
                        cb null, httpSettings

                if httpsVars.tls.then
                    httpsVars.tls.then =>
                        httpsVars.tls = tls.createServer httpsVars.tlsOptions, (c) =>
                            libHTTPS.getStream "127.0.0.1", httpSettings.port, (err, stream) ->
                                if err?
                                    tlsLog.error gLineInfo "Tunnel failed: Could not connect to HTTP Server"
                                    c?.destroy()
                                    return stream?.destroy()
                                c.pipe(stream).pipe(c)
                        httpsVars.tls.on "error", (err) ->
                            tlsLog.error gLineInfo(), err
                            gErr err.message
                        httpsVars.tls.listen httpSettings.internalTLSPort, "127.0.0.1", ->
                            tlsLog.info "Listening"
                            listen()
                else
                    listen()
                
        shutdown: ->
            @shutdownCheck (cb) =>
                httpsVars.tls.close() # node docs don't indicate this takes a callback
                httpsVars.tls = Promise.resolve() # TODO: Simon, this hack is necessary
                                                  #       because without it test/https.coffee
                                                  #       breaks if it is not run first.
                                                  #       This happens because of the
                                                  #       `if httpsVars.tls.then` above
                                                  #       in `start:`.
                @server.close cb

        callback: (c, cb) ->
            libHTTPS.getClientHello c, (err, category, host, buf) =>
                @log.debug err, category, host, buf?.length
                if err?
                    @log.debug gLineInfo "TCP handling: "+err.message
                    cb()
                    return c?.destroy()

                # UNBLOCK: Check if needs to be hijacked

                isRouted = false # unblockSettings.enabled and unblockSettings.routeDomains[host]?
                isDNSChain = (
                    (category == libHTTPS.categories.NO_SNI) or
                    ((not unblockSettings.enabled) and category == libHTTPS.categories.SNI) or
                    (unblockSettings.enabled and (host in unblockSettings.acceptApiCallsTo)) or
                    ((host?.split(".")[-1..][0]) == "dns")
                )
                isUnblock = false

                [destination, port, error] = if isRouted
                    ["127.0.0.1", unblockSettings.routeDomains[host], false]
                else if isDNSChain
                    ["127.0.0.1", httpSettings.internalTLSPort, false]
                else if isUnblock
                    [host, 443, false]
                else
                    ["", -1, true]

                if error
                    @log.error "Illegal domain (#{host})"
                    cb()
                    return c?.destroy()

                libHTTPS.getStream destination, port, (err, stream) =>
                    if err?
                        @log.error gLineInfo "Tunnel failed: Could not connect to internal TLS Server"
                        c?.destroy()
                        cb()
                        return stream?.destroy()
                    stream.write buf
                    c.pipe(stream).pipe(c)
                    c.resume()
                    @log.debug gLineInfo "Tunnel: #{host}"
                    cb()

        getFingerprint: -> httpsVars.fingerprint