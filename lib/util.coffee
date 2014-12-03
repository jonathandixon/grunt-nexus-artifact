http = require 'http'
fs = require 'fs'
Q = require 'q'
crypto = require 'crypto'
urlUtil = require 'url'

module.exports = (grunt) ->

  compress = require('grunt-contrib-compress/tasks/lib/compress')(grunt)

  downloadFile = (artifact, path, temp_path, expand) ->
    deferred = Q.defer()

    # http.get artifact.buildUrl(), (res) ->

    #   file = fs.createWriteStream temp_path
    #   res.pipe file

    #   res.on 'error', (error) -> deferred.reject (error)
    #   file.on 'error', (error) -> deferred.reject (error)

    #   res.on 'end', ->
    grunt.util.spawn
      cmd: 'curl'
      args: "-k -o #{temp_path} #{artifact.buildUrl()}".split(' ')
    , (err, stdout, stderr) ->
      if err
        deferred.reject err
        return

      spawnCmd = {}

      if expand is false
        grunt.log.writeln 'Not expanding artifact.'
        spawnCmd = 
          cmd: 'echo'
          args: [ 'Not expanding artifact.' ]
      else if artifact.ext is 'tgz'
        spawnCmd =
          cmd: 'tar'
          args: "zxf #{temp_path} -C #{path}".split ' '
      else if artifact.ext in [ 'zip', 'jar' ]
        spawnCmd =
          cmd : 'unzip',
          args: "-o #{temp_path} -d #{path}".split(' ')
      else
        msg = "Unknown artifact extension (#{artifact.ext}), could not extract it"
        deferred.reject msg

      grunt.util.spawn spawnCmd, (err, stdout, stderr) ->
        grunt.file.delete temp_path if expand

        if err
          deferred.reject err
          return

        filePath = "#{path}/.downloadedArtifacts"
        downloadedArtifacts = if grunt.file.exists(filePath) then grunt.file.readJSON(filePath) else {}
        downloadedArtifacts[artifact.toString()] = new Date()
        grunt.file.write filePath, JSON.stringify(downloadedArtifacts)

        deferred.resolve()

    deferred.promise

  uploadCurl = (filename, url, credentials) ->
    deferred = Q.defer()
    authStr = if credentials.username then "-u #{credentials.username}:#{credentials.password}"  else ''

    grunt.util.spawn
      cmd: 'curl'
      args: "-T #{filename} #{authStr} #{url}".split ' '
    , (err, result, code) ->
      grunt.log.writeln "Uploaded #{filename.cyan}"
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

      # allow upload through curl
      uploadFn = if options.curl then uploadCurl else upload

      promises = [
        uploadFn options.path + filename, url, options.credentials
        upload hashes.sha1, "#{url}.sha1", options.credentials, false
        upload hashes.md5, "#{url}.md5", options.credentials, false
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

  return {

  ###*
  * Download an nexus artifact and extract it to a path
  * @param {NexusArtifact} artifact The nexus artifact to download
  * @param {String} path The path the artifact should be extracted to
  *
  * @return {Promise} returns a Q promise to be resolved when the file is done downloading
  ###
  download: (artifact, path, expand = true) ->
    deferred = Q.defer()

    filePath = "#{path}/.downloadedArtifacts"
    if grunt.file.exists(filePath)
      downloadedArtifacts = grunt.file.readJSON(filePath)
      if downloadedArtifacts[artifact.toString()]
        grunt.log.writeln "Up-to-date: #{artifact}"
        return

    grunt.file.mkdir path

    temp_path = "#{path}/#{artifact.buildArtifactUri()}"
    grunt.log.writeln "Downloading #{artifact.buildUrl()}"

    downloadFile(artifact, path, temp_path, expand).then( ->
      deferred.resolve(temp_path)
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
  verify: (artifact, path) ->

    deferred = Q.defer()

    @download(artifact, path).then( () ->
        grunt.log.writeln "Download and unpack of archive successful"
        deferred.resolve()
      ).fail ( (err) ->
        grunt.log.writeln "There was a problem downloading and unpacking the created archive. Error: #{ err }"
        deferred.reject err
      )

    deferred.promise

  }
