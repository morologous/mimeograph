#
# Dependencies
#
fs                       = require 'fs'
resque                   = require 'coffee-resque'
{spawn}                  = require 'child_process'
{redisfs}                = require 'redisfs'
{_, log, puts, copyFile} = require './utils'
async                    = require 'async'
path                     = require 'path'
pkginfo                  = require('pkginfo')(module)

mimeograph         = exports
mimeograph.version = module.exports.version
# although pdf beads works with a variety of image types
# it will only process images with certain extension - regardless
# of the actual image type.  this happens to be one that pdfbeads
# plays nicely with
mimeograph.imageExtension = 'png'

#
# export to global scope.  not ideal.
#
expose = (host, port) ->
  redisfs = redisfs
    namespace : 'mimeograph'
    prefix    : 'mimeograph-'
    encoding  : 'base64'
    host      : host
    port      : port

  global.redisfs    = redisfs
  global.redis      = redisfs.redis
  global.file2redis = _.bind redisfs.file2redis, redisfs
  global.redis2file = _.bind redisfs.redis2file, redisfs

#
# @abstract
# Base class for mimeograph jobs.
#
class Job
  constructor: (@context, @callback) ->
    {@key, @jobId} = @context

  complete: (result) ->
    @callback _.extend @context, result

  fail: (err) ->
    @callback if _.isString err then new Error err else err

  #
  # thin wrapper around child_processes.spawn.  will capture error output
  # during execution of child process and log that output to error if the
  # child_process returns with a code other than 0. regardless of the code
  # value, the onExitCallback passed into this method will be evaluated
  # when the error log has been completed.
  #
  # unlike the original child_process.spawn args & options should be passed
  # in the settings object as values for the keys "args" and "options"
  # respectively. the settings argument is optional and if it is passed the
  # "args" and options" keys are still optional.
  #
  spawn: (command, settings..., callback) ->
    settings = settings[0] || {}
    commandInfo = "#{command} #{JSON.stringify settings}"
    proc = spawn command, settings.args, settings.options

    proc.stderr.on 'data', (data) ->
      @errorData = [] unless @errorData?
      @errorData.push data

    proc.on 'exit', (code) ->
      # handle error - have to check code & errorData because pdfbeads output
      # what appears to be non-error info to stderr.
      if code
        log.err "failure running #{commandInfo}"
        log.err "#{error}" for error in @errorData if @errorData
      #pass control back to original callback
      callback code

#
# Extract the text from the pdf using pdftotext.
#
# callback will receive a hash with a 'text' field containing
# the accumlated text found in the pdf.
#
class Extractor extends Job
  perform: ->
    log "extracting  - #{@key}"
    redis2file @key, file: @key, deleteKey: false, (err) =>
      return @fail err if err?
      @extract()

  extract: ->
    proc = @spawn 'pdftotext', args:[@key], (code) =>
      return @fail "pdftotext exit(#{code})" if code
      @fetchText()

  fetchText: ->
    @file = "#{_.basename @key}.txt"
    fs.readFile @file, 'utf8', (err, text) =>
      return @fail err if err?
      fs.unlink file for file in [@file, @key]
      @complete text: text

#
# Split the pdf file into individual pdf files with 1
# page each using pdftk burst.
#
# callback will receive a hash with a 'pages' propery
# containing and array of all the paths produced by
# ghostscript.
#
class Splitter  extends Job
  constructor: (@context, @callback, @pages = []) ->
    super @context, @callback
    @basename = _.basename @key
    @args = [
      @key,
      "burst",
      "output",
      "#{@basename}-%04d.pdf"
    ]

  perform: ->
    log "splitting   - #{@key}"
    redis2file @key, file: @key, (err) =>
      return @fail err if err?
      @split()

  split: ->
    proc = @spawn 'pdftk', args: @args, (code) =>
      return @fail "pdftk exit(#{code})" if code
      @fetchPages()

  fetchPages: ->
    fs.readdir '/tmp', (err, files) =>
      return @fail err if err?
      @findPages @basename, "#{file}" for file in files
      fs.unlink @key
      @complete pages: @pages

  findPages: (basename, file) ->
    basename = basename.substr basename.lastIndexOf('/') + 1
    @pages.push "/tmp/#{file}" if file.match "^#{basename}-{1}"

#
# Convert a one page pdf into a single image using
# Ghostscript
#
# callback will receive the path to the image
# created by ghostscript.
class Converter extends Job
  constructor: (@context, @callback) ->
    super @context, @callback
    @image = "#{_.basename @key}.#{mimeograph.imageExtension}"
    @args = [
      '-SDEVICE=jpeg',
      '-sPAPERSIZE=letter',
      '-r240x240',
      "-sOutputFile=#{@image}",
      '-dTextAlphaBits=4',
      '-dBATCH',
      '-dNOPAUSE',
      '-dSAFER',
      '--'
      @key
    ]

  perform: ->
    log "converting   - #{@key}"
    # do not delete - still need to merge hocr
    redis2file @key, file: @key, deleteKey: false, (err) =>
      return @fail err if err?
      @split()

  split: ->
    proc = @spawn 'gs', args: @args, (code) =>
      return @fail "gs exit(#{code})" if code
      @fetchPage()

  fetchPage: ->
    path.exists @image, (exists) =>
      return @fail "@image file was not found" unless exists
      @complete image: @image
      fs.unlink 'doc_data.txt' #metadata file created by pdftk burst

#
# Recognize (ocr) the text, in hocr format, from the images using
# tesseract.
#
# callback will receive a hash with a 'hocr' field containing
# the path to the hocr result.
#
class Recognizer extends Job
  constructor: (@context, @callback) ->
    super @context, @callback
    basename  = _.basename @key
    #hocr generates file with html extension
    @file      = "#{basename}.html"
    @args = [
      @key,
      basename,
      "+#{__dirname}/tesseract_hocr_config.txt"
    ]

  perform: ->
    log "recognizing - #{@key}"
    redis2file @key, file: @key, (err) =>
      return @fail err if err?
      @recognize()

  recognize: ->
    jobStatus @jobId, (status) =>
      if status isnt 'fail'
        proc = @spawn 'tesseract', args:@args, (code) =>
          return @fail "tesseract exit(#{code})" if code
          @fetchText()
      else
        fs.unlink @key
        @complete()

  fetchText: ->
    fs.readFile @file, 'utf8', (err, text) =>
      return @fail err if err?
      fs.unlink @key
      @complete hocr: @file

#
# Generate the searchable PDF for a single page using pdfbeads.
#
# callback will receive a hash with a 'page' field containing
# the path to the searchable pdf page and a 'pageNumber' field
# containing the page number of the 'page' in the ultimate pdf.
#
class PageGenerator extends Job
  constructor: (@context, @callback) ->
    super @context, @callback
    @basename = _.basename @key
    @image = "#{@basename}.#{mimeograph.imageExtension}"
    @hocrPath = "#{@basename}.hocr"
    # this will ensure that we don't overwrite the original pdf
    # page in redis
    @page = "#{@basename}.spdf"

  perform: ->
    log "generating - #{@page}"
    async.parallel [@fetchHocr, @copyImage], @generate

  fetchHocr: (callback) =>
    redis2file @key, file: @hocrPath, encoding: 'utf8', (err) =>
      callback err

  copyImage: (callback) =>
    # TODO explore ways to dynamically generate image
    # to better fit various dimensions etc.  however, this
    # will most likely need a rethink of ghostscript's use
    # of '-sPAPERSIZE=letter'.  we could use Imagemagick convert
    # to create the image and then "cache it".  parsing the hocr
    # file will reveal the bbox dimensions of the "ocr_page"
    copyFile "#{__dirname}/blank.jpg", @image, (err) ->
      callback err

  generate: (err) =>
    return @fail "#{err}" if err?
    generator_path = path.join(__dirname, "mimeo_pdfbeads.rb")
    #72dpi is sufficient for most displays and 240dpi is sufficient for printing
    args = [generator_path, path.basename(@image),  "-o", "#{@page}", "-B", "240", "-d"]
    # execute the mimeo_pdfbeads.rb script via ruby cli. this avoids the need to:
    # -include mimeo_pdfbeads as a executable in this package, which would
    #expose this ugliness to the user
    # -having to ensure that mimeo_pdfbeads has executable permission
    proc = @spawn "ruby", args: args, options: {cwd: path.dirname(@image)}, (code) =>
      return @fail "pdfbeads exit(#{code})" if code
      fs.unlink file for file in [@image, @hocrPath]
      # not returning contents of @page - just the file path
      @complete page: @page

#
# Layer the original PDF on top of the searchable PDF
# using pdftk.  this will generate a searchable PDF that
# appears visually indistinguisable from the original page.
#
# callback will receive a hash with a 'page' field containing
# the path to the new layered searchable pdf page and
# a 'pageNumber' field containing the page number of the
# 'page' in the ultimate pdf.
#
class PdfLayer extends Job
  constructor: (@context, @callback) ->
    super @context, @callback
    # derive backgroundPage and foregroundPage from key
    @backgroundPage = @key
    @foregroundPage = "#{_.basename @key}.pdf"
    # output file name needs to be different from source files
    @layeredPage = "#{_.basename @key}.lpdf"
    @args = [
      @foregroundPage,
      "background",
      @backgroundPage,
      "output",
      @layeredPage
    ]

  perform: ->
    log "layering  - #{@key}"
    async.forEach [@backgroundPage, @foregroundPage], @fileFetcher, @layer

  layer: (err) =>
    return @fail err if err?
    proc = @spawn "pdftk", args: @args, (code) =>
      return @fail "pdftk exit(#{code})" if code
      fs.unlink file for file in [@backgroundPage, @foregroundPage]
      @complete page: @layeredPage, pageNumber: _.pageNumber @layeredPage

  fileFetcher: (key, callback) ->
    redis2file key, file: key, (err) =>
      log.err "error accessing #{key}" if err?
      callback err

#
# Generate the searchable PDF by combining all of the individual
# pages generated for the PDF.
#
# callback will receive a hash with a 'page' field containing
# the path to the completed pdf page.
#
class PdfStitcher extends Job
  constructor: (@context, @callback, @pages = []) ->
    super @context, @callback
    @keys = @key # @keys is an array of redis keys
    @page = "#{_.stripPageNumber @key[0]}.pdf"
    @args = ["output", @page]

  perform: ->
    log "stitching - #{@jobId}:#{@keys}"
    async.map @keys, @fetchPage, (err, results) =>
      return @fail err if err?
      @stitch results

  stitch: (pages) ->
    proc = @spawn 'pdftk', args: pages.concat(@args), options: {cwd: path.dirname(@page)}, (code) =>
      return @fail "pdftk exit(#{code})" if code
      @cleanup pages
      @complete page: @page

  fetchPage: (pageKey, callback) ->
    redis2file pageKey, file: pageKey, callback

  cleanup: (pages) ->
    fs.unlink page for page in pages

#
# The resque jobs.
#
jobs =
  extract       : (context, callback) -> new Extractor(context, callback).perform()
  split         : (context, callback) -> new Splitter(context, callback).perform()
  convert       : (context, callback) -> new Converter(context, callback).perform()
  hocr          : (context, callback) -> new Recognizer(context, callback).perform()
  pdf           : (context, callback) -> new PageGenerator(context, callback).perform()
  layer         : (context, callback) -> new PdfLayer(context, callback).perform()
  stitch        : (context, callback) -> new PdfStitcher(context, callback).perform()
  lastextract   : (context, callback) -> new Extractor(context, callback).perform()

#
# Namespace util for redis key gen.
#
genkey = (args...) ->
  args.unshift "mimeograph:job"
  args.join ':'

#
# Get a jobs status
#
jobStatus = (jobId, callback) ->
  redis.hget genkey(jobId), 'status', (err, status) =>
    callback status

#
# Manages the process.
#
class Mimeograph
  constructor: (host, port, count, @workers = []) ->
    expose host, port
    @resque = resque.connect
      redis     : redis
      namespace : 'resque:mimeograph'
    @worker i for i in [0...count]
    process.on 'SIGINT',  @end
    process.on 'SIGTERM', @end
    process.on 'SIGQUIT', @end

  #
  # Start the workers.
  #
  start: ->
    worker.start() for worker in @workers
    log.warn "OK - mimeograph started with #{@workers.length} workers."

  #
  # Kick off a new job.
  #
  process: (id, file) ->
    try
      status = fs.lstatSync file
      throw Error "'#{file}' is not a file." unless status.isFile()
      if id? then @createJob id, file
      else redis.incr genkey('ids'), (err, id) =>
        return @capture err if err?
        @createJob _.lpad(id), file
    catch error
      puts.stderr "#{error.message}"
      @end()

  #
  # Creates a new mimeograph process job and
  # schedule an extract job.
  #
  createJob: (jobId, file) ->
    key = @filename jobId
    redis.hset genkey(jobId), 'started', _.now()
    file2redis file, key: key, (err) =>
      return @capture err, {jobId: jobId} if err?
      @enqueue 'extract', key, jobId
      log "OK - created #{genkey(jobId)} for file #{file}"
      @end()

  #
  # Generate a file name.
  #
  filename: (jobId) ->
    "/tmp/mimeograph-#{jobId}.pdf"

  #
  # Rescue worker's success callback.
  # Orchestrates the job steps.
  #
  success: (worker, queue, job, result) =>
    switch job.class
      when 'extract'     then @split result
      when 'split'       then @convert result
      when 'convert'     then @hocr result
      when 'hocr'        then @pdf result
      when 'pdf'         then @layer result
      when 'layer'       then @stitch result
      when 'stitch'      then @complete result
      when 'lastextract' then @recordText result

  #
  # Schedule a split job if ocr is required,
  # ie the extract step didn't produce any text.
  # If ocr isn't required the job is finished and
  # the text is set in the text key for the
  # job.
  #
  split: (result) ->
    {jobId, key, text} = result
    if text.trim().length
      @recordText result
    else
      @enqueue 'split', key, jobId

  recordText: ({jobId, key, text}) ->
    multi = redis.multi()
    multi.del  key
    multi.hset genkey(jobId), 'text', text
    multi.exec (err, result) =>
      return @capture err, result if err?
      @finalize jobId

  #
  # Set the number of pages that came out of the
  # split step.  For each split file store the
  # the file in redis and schedule an convert job.
  #
  convert: (result) ->
    {jobId, pages} = result
    redis.hset genkey(jobId), 'num_pages', pages.length, (err) =>
      return @capture err, result if err?
      @storeAndEnqueue page, 'convert', jobId for page in pages

  #
  # Store the image and in redis and schedule an hocr job.
  #
  hocr: (result) ->
    {jobId, image} = result
    @storeAndEnqueue image, 'hocr', jobId

  #
  # Store the hocr result in redis and schedule a pdf
  # job.
  #
  pdf: (result) ->
    {jobId, hocr} = result
    @storeAndEnqueue hocr, 'utf8', 'pdf', jobId

  #
  # Store the searchable page in a redis hash and schedule
  # a layer job that pdf with the original pdf page
  #
  layer: (result) ->
    {jobId, page} = result
    @storeAndEnqueue page, 'layer', jobId

  #
  # Store the final page in a redis hash and determine
  # if all the pages have been recognized at which point
  # finish.
  #
  stitch: (result) ->
    {jobId, pageNumber, page} = result
    # add the searchable page to a key
    file2redis page, key: page, (err) =>
      return @capture err, {jobId: jobId, page: page, desc: 'error in Mimeograph.stitch() writing page'} if err?
      # file is written - write the rest to redis
      @recordPageComplete jobId, _.stripPageNumber(page)

  #
  # Record the completion of a page and then determine if
  # page processing has been completed.
  #
  recordPageComplete: (jobId, baseKey) ->
    multi = redis.multi()
    # increment the number of pages processed by one
    multi.hincrby genkey(jobId), 'num_processed', 1
    # fetch total number of pages in the pdf
    multi.hget    genkey(jobId), 'num_pages'
    multi.exec (err, results) =>
      return @capture err, results if err?
      [processed, total] = results
      @checkComplete jobId, baseKey, processed, parseInt total

  #
  # Determine if all the pages have been processed and
  # finalize if so.
  #
  checkComplete: (jobId, baseKey, processed, total) ->
    # if all individual pages have been processed
    if processed is total
      #is count of error pages equal to total
      errorskey = genkey jobId, 'error_pages'
      redis.zcount errorskey, "-inf", "+inf", (err, results) =>
        return @capture err, results if err?
        return @fatalError jobId, "Recorded failure for every page" if total is parseInt(results)
        # stitch the pages together
        @gatherPages jobId, baseKey, (results) =>
          @enqueue 'stitch', results.sort(), jobId

  #
  # Collect the keys for final pages generated for this
  # jobId.  The callback will be passed a single argument, an
  # array of keys.
  #
  gatherPages: (jobId, baseKey, callback) ->
    pdfFile = /.*\.lpdf$/
    redis.keys "#{baseKey}*", (err, results) =>
      return @capture err, {jobId: jobId} if err?
      callback (result for result in results when pdfFile.test(result))

  #
  # Once the searchable pdf is ready this method will
  # enqueue a text extraction job once again.
  #
  complete: (result) ->
    {jobId, page} = result
    # TODO need to push a change to redisfs to have more flexibility
    # in the datastructure you want to store files in
    fs.readFile page, "base64", (err, data) =>
      key   = genkey jobId
      field = "outputpdf"
      # TODO only store the doc once - this is a little ugly
      # store the doc in the hset then in the key for the extract job
      redis.hset key, field, data, (err, results) =>
        return @capture err, {jobId: jobId, desc: "error in complete"} if err?
        key = @filename jobId
        @storeAndEnqueue page, 'lastextract', jobId

  #
  # Wrap up the job and publish a notification
  #
  finalize: (jobId) ->
    #gather data from error page sorted set
    errorskey = genkey jobId, 'error_pages'
    redis.zrange errorskey, 0, -1, (err, errors) =>
      return @capture err, {jobId: jobId} if err?
      multi = redis.multi()
      job   = genkey jobId
      multi = redis.multi()
      # delete data in error page sorted set
      multi.del  errorskey, errorskey
      # denote error pages in final results hash
      multi.hset job, 'error_pages', errors.join ',' unless _.isEmpty errors
      multi.hset job, 'ended', _.now()
      multi.hset job, 'status', 'complete'
      multi.hdel job, 'num_processed'
      multi.exec (err, results) =>
        return @capture err, result if err?
        @notify job

  #
  # Attempt to notify clients about job completeness.
  # In the event where there were no subscribers
  # add the job to the completed set.  Sort of a poor
  # mans durability solution.
  #
  notify: (job, status = 'complete') ->
    log "notifying #{job} #{status}"
    redis.publish job, "#{job}:#{status}", (err, subscribers) =>
      return @capture err, result if err?
      redis.sadd genkey('completed'), job  unless subscribers

  #
  # Pushes a job onto the queue.  Each job receives a
  # context which includes the id of the job being
  # processed and a key which usually points to a file
  # in redis that is required by the job to carry out
  # it's work.
  #
  enqueue: (job, key, jobId) ->
    @resque.enqueue 'mimeograph', job, [
      key   : key
      jobId : jobId
    ]

  #
  # Store a file in redis and schedule a job.
  #
  storeAndEnqueue: (file, encoding..., job, jobId) ->
    options = key: file
    options.encoding = encoding.shift() unless _.isEmpty encoding
    file2redis file, options, (err) =>
      return @capture err, {jobId: jobId, job: job} if err?
      @enqueue job, file, jobId

  #
  # Resque worker's error handler.  In the case of a failed ocr
  # job track the error (page number) and follow the 'success'
  # path via @finish.  This is to support partial failures.  For
  # the other classes of jobs fail and publish the failed message.
  #
  error: (error, worker, queue, job) =>
    if job?
      if job.class in ['hocr','pdf']
        @handlePageJobError job, error
      else
        jobId = job.args[0].jobId
        log.err "error       - #{jobId} #{job.class} #{error}"
        # error coming back from CoffeeResque is going to be an instance
        # of Error - lets attach its contents to the job so that
        # the published failure is a little more descriptive
        job.error = error.toString()
        @fatalError jobId, JSON.stringify job
    #if there is an error starting up (e.g. redis is unreachable) job is null
    else
      log.err "error       - #{error}"

  #
  # Handler for job errors that impact a single page and that should not cause
  # the discontinuation of processing.
  #
  # TODO: if a one page doc fails during pagegeneration i don't believe
  # that mimeo will publish the failure.
  #
  handlePageJobError: (job, error) =>
    jobId = job.args[0].jobId
    pageNumber = _.pageNumber(job.args[0].key)
    log.err "error       - #{jobId} #{job.class} #{error} page: #{pageNumber}"
    errorsKey = genkey jobId, 'error_pages'
    redis.zadd errorsKey, pageNumber, pageNumber, (err) =>
      return @capture err if err?
      @recordPageComplete jobId, _.stripPageNumber(job.args[0].key)

  #
  # Finalizes a job due to errors that should cause the discontinuation of
  # processing.
  #
  # Although this may kill the current resque job, and result in the
  # client receiving a fail notification, there may be other resque jobs queued
  # up related to the same source PDF.  those other resque jobs will still be
  # processed.
  #
  # TODO - clean up other related resque jobs with a related jobId
  #
  fatalError: (jobId, errorMessage) ->
    multi = redis.multi()
    multi.del  @filename jobId
    multi.hset genkey(jobId), 'status', 'failed'
    multi.hset genkey(jobId), 'error' , errorMessage
    multi.exec (err) =>
      return @capture err, {jobId: jobId} if err?
      @notify genkey(jobId), 'fail'

  #
  # Construct the named resque workers that carry out
  # the jobs.
  #
  worker: (name) ->
    @workers.push worker = @resque.worker 'mimeograph', jobs
    worker.name = "mimeograph:#{name}"
    worker.on 'error',   @error
    worker.on 'success', @success
    worker

  #
  # All done, disconnect the redis client.
  #
  end: =>
    log.warn 'Shutting down!'
    @stopWorkers =>
      if @resque? then @resque.end() else redisfs.end()

  #
  # Shutdown all the workers, callsback when done
  #
  stopWorkers: (done) ->
    if worker = @workers.pop()
      worker.end => @stopWorkers done
    else
      done()

  #
  # Log the err.
  #
  # todo: add the jobId here and error notification.
  #
  capture: (err, meta) -> log.err "#{JSON.stringify meta} #{JSON.stringify err}"

#
# exports
#
mimeograph.process = (args, host, port) ->
  id   = args.shift() if args.length is 2
  file = args.shift()
  new Mimeograph(host, port).process id, file

mimeograph.start = (host, port, workers = 5) ->
  new Mimeograph(host, port, workers).start()