"use strict"
Q = require 'q'

module.exports = (grunt) ->
  NexusArtifact = require('../lib/nexus-artifact')(grunt)
  util = require('../lib/util')(grunt)

  # shortcut to underscore
  _ = grunt.util._

  grunt.registerMultiTask 'nexus', 'Download an artifact from nexus', ->
    done = @async()

    # defaults
    options = this.options
      url: ''
      base_path: 'nexus/content/repositories'
      repository: ''
      versionPattern: '%a-%v.%e'
      username: ''
      password: ''
      curl: false
      expand: true
      delete: true
      cacert: ''

    processes = []

    if !@args.length or _.contains @args, 'fetch'
      _.each options.fetch, (cfg) ->
        # get the base nexus path
        _.extend cfg, NexusArtifact.fromString(cfg.id) if cfg.id
        _.extend cfg, options, cfg

        cfg.expandPath ?= cfg.path

        artifact = new NexusArtifact cfg

        processes.push util.download(artifact, cfg)

    if @args.length and _.contains @args, 'publish'
      _.each options.publish, (cfg) =>
        _.extend cfg, NexusArtifact.fromString(cfg.id) if cfg.id
        _.extend cfg, options, cfg

        artifact = new NexusArtifact cfg

        processes.push util.publish(artifact, @files, cfg)

    if @args.length and _.contains @args, 'verify'
      _.each options.verify, (cfg) =>

        _.extend cfg, NexusArtifact.fromString(cfg.id) if cfg.id
        _.extend cfg, options, cfg

        artifact = new NexusArtifact cfg

        processes.push util.verify(artifact, cfg)

    Q.all(processes).then(() ->
      done()
    ).fail (err) ->
      grunt.fail.warn err
