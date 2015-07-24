http = require 'http'
fs = require 'fs'
Q = require 'q'
crypto = require 'crypto'
urlUtil = require 'url'

module.exports = (grunt) ->

  compress = require('grunt-contrib-compress/tasks/lib/compress')(grunt)

  downloadFile = (artifact, temp_path, options) ->
    deferred = Q.defer()

    curl_cert_opt = if options.cacert then "--cacert #{options.cacert}" else ''
    curl_auth_opt = if options.username then "-u #{options.username}:#{options.password}"  else ''

    # http.get artifact.buildUrl(), (res) ->

    #   file = fs.createWriteStream temp_path
    #   res.pipe file

    #   res.on 'error', (error) -> deferred.reject (error)
    #   file.on 'error', (error) -> deferred.reject (error)

    #   res.on 'end', ->
    grunt.util.spawn
      cmd: 'curl'
      args: "#{curl_cert_opt} #{curl_auth_opt} -o #{temp_path} #{artifact.buildUrl()}".split(' ')
    , (err, stdout, stderr) ->
      if err
        deferred.reject err
        return

      spawnCmd = {}

      if options.expand is false
        grunt.log.writeln 'Not expanding artifact.'
        spawnCmd =
          cmd: 'echo'
          args: [ 'Not expanding artifact.' ]
      else if artifact.ext is 'tgz'
        spawnCmd =
          cmd: 'tar'
          args: "zxf #{temp_path} -C #{options.expandPath}".split ' '
      else if artifact.ext in [ 'zip', 'jar' ]
        spawnCmd =
          cmd : 'unzip',
          args: "-o #{temp_path} -d #{options.expandPath}".split(' ')
      else
        msg = "Unknown artifact extension (#{artifact.ext}), could not extract it"
        deferred.reject msg

      grunt.util.spawn spawnCmd, (err, result, code) ->
        grunt.file.delete temp_path if options.expand and options.delete

        if err and spawnCmd.cmd != 'echo'
          if options.ignoreUnpackError
            msg = String(err.message || err);
            grunt.log.error msg
          else
            deferred.reject err
            return

        filePath = "#{options.path}/.downloadedArtifacts"
        downloadedArtifacts = if grunt.file.exists(filePath) then grunt.file.readJSON(filePath) else {}
        downloadedArtifacts[artifact.toString()] = new Date()
        grunt.file.write filePath, JSON.stringify(downloadedArtifacts)

        deferred.resolve()

    deferred.promise

  uploadCurl = (data, url, credentials, isFile, cacert) ->
    deferred = Q.defer()
    authStr = if credentials.username then "-u #{credentials.username}:#{credentials.password}"  else ''
    certStr = if cacert then "--cacert #{cacert}" else ''
    uploadOpt = if isFile then '-T' else '-d'

    grunt.util.spawn
      cmd: 'curl'
      args: "#{certStr} #{uploadOpt} #{data} #{authStr} #{url}".split ' '
    , (err, result, code) ->
      grunt.log.writeln "Uploaded #{data.cyan}"
      deferred.reject err if err

      deferred.resolve()

    deferred.promise

  upload = (data, url, credentials, isFile = true) ->
    deferred = Q.defer()

    options = grunt.util._.extend urlUtil.parse(url), {method: 'PUT'}
    if credentials.username
      options = grunt.util._.extend options, {auth: credentials.username + ":" + credentials.password}

    request = http.request options

    if isFile
      file = fs.createReadStream(data)
      destination = file.pipe(request)

      destination.on 'end', ->
        grunt.log.writeln "Uploaded #{data.cyan}"
        deferred.resolve()

      destination.on 'error', (error) -> deferred.reject error
      file.on 'error', (error) -> deferred.reject error
      request.on 'error', (error) -> deferred.reject error
    else
      request.end data
      deferred.resolve()

    deferred.promise

  publishFile = (options, filename, urlPath) ->
    deferred = Q.defer()

    generateHashes(options.path + filename).then (hashes) ->

      url = urlPath + filename
      credentials =
        username: options.username
        password: options.password

      # allow upload through curl
      uploadFn = if options.curl then uploadCurl else upload

      promises = [
        uploadFn options.path + filename, url, credentials, true, options.cacert
        uploadFn hashes.sha1, "#{url}.sha1", credentials, false, options.cacert
        uploadFn hashes.md5, "#{url}.md5", credentials, false, options.cacert
      ]

      Q.all(promises).then () ->
        deferred.resolve()
      .fail (error) ->
        deferred.reject error
    .fail (error) ->
      deferred.reject error

    deferred.promise

  generateHashes = (file) ->
    deferred = Q.defer()

    md5 = crypto.createHash 'md5'
    sha1 = crypto.createHash 'sha1'

    stream = fs.ReadStream file

    stream.on 'data', (data) ->
      sha1.update data
      md5.update data

    stream.on 'end', (data) ->
      hashes =
        md5: md5.digest 'hex'
        sha1: sha1.digest 'hex'
      deferred.resolve hashes

    stream.on 'error', (error) ->
      deferred.reject error

    deferred.promise

  shouldDownloadFile = (artifact, options) ->
    deferred = Q.defer()
    filePath = "#{options.path}/.downloadedArtifacts"
    downloadedArtifacts = if grunt.file.exists(filePath) then grunt.file.readJSON(filePath) else {}

    if downloadedArtifacts[artifact.toString()]
      if artifact.toString().indexOf('SNAPSHOT') > 0
        curl_cert_opt = if options.cacert then "--cacert #{options.cacert}" else ''
        curl_auth_opt = if options.username then "-u #{options.username}:#{options.password}"  else ''

        grunt.util.spawn
          cmd: 'curl'
          args: "#{curl_cert_opt} #{curl_auth_opt} -I #{artifact.buildUrl()}".split(' ')
        , (err, stdout, stderr) ->
          if err
            deferred.reject err
            return

          # Check Last Modified date of SNAPSHOT.
          lastModified = String(stdout).match /Last-Modified:\s*(.*)/
          if lastModified and new Date(downloadedArtifacts[artifact.toString()]) < new Date(lastModified[1])
            deferred.resolve true
          else
            deferred.resolve false
      else
        # Current version of artifact has already been downloaded.
        deferred.resolve false
    else
      # No record of download.
      deferred.resolve true

    deferred.promise

  return {

  ###*
  * Download an nexus artifact and extract it to a path
  * @param {NexusArtifact} artifact The nexus artifact to download
  * @param {String} path The path the artifact should be extracted to
  *
  * @return {Promise} returns a Q promise to be resolved when the file is done downloading
  ###
  download: (artifact, options) ->
    deferred = Q.defer()

    shouldDownloadFile(artifact, options).then( (doDownload) ->
      temp_path = "#{options.path}/#{artifact.buildArtifactUri()}"

      if doDownload
        grunt.file.mkdir options.path

        grunt.log.writeln "Downloading #{artifact.buildUrl()}"

        downloadFile(artifact, temp_path, options).then( ->
          deferred.resolve temp_path
        ).fail (error) ->
          deferred.reject error
      else
        grunt.log.writeln "Up-to-date: #{artifact}"
        deferred.resolve temp_path
    ).fail (error) ->
      deferred.reject error

    deferred.promise

  ###*
  * Publish a path to nexus
  * @param {NexusArtifact} artifact The nexus artifact to publish to nexus
  * @param {String} path The path to publish to nexus
  *
  * @return {Promise} returns a Q promise to be resolved when the artifact is done being published
  ###
  publish: (artifact, files, options) ->
    deferred = Q.defer()
    filename = artifact.buildArtifactUri()
    archive = "#{options.path}#{filename}"

    compress.options =
      archive: archive
      mode: compress.autoDetectMode(archive)

    compress.tar files, () ->
      publishFile(options, filename, artifact.buildUrlPath()).then( ->
        deferred.resolve()
      ).fail (error) ->
        deferred.reject error

    deferred.promise

  ###*
  * Verify the integrity of the tar file published by this grunt task after publishing.
  * @param {NexusArtifact} artifact to publish to nexus
  * @param {String} path to publish to nexus
  *
  * @return {Promise} returns a Q promise to be resolved when the artifact is done being downloaded & unpacked
  ###
  verify: (artifact, options) ->

    deferred = Q.defer()

    @download(artifact, options).then( () ->
        grunt.log.writeln "Download and unpack of archive successful"
        deferred.resolve()
      ).fail ( (err) ->
        grunt.log.writeln "There was a problem downloading and unpacking the created archive. Error: #{ err }"
        deferred.reject err
      )

    deferred.promise

  }
