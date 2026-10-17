#!/usr/bin/env ruby
# frozen_string_literal: true

# lazys3 - bruteforce AWS S3 bucket names via permutations.
# For authorized security testing and research only.

require 'net/http'
require 'uri'
require 'optparse'
require 'json'
require 'csv'
require 'thread'

module Color
  def self.wrap(text, code)
    return text unless $stdout.tty?

    "\e[#{code}m#{text}\e[0m"
  end

  def self.red(t);    wrap(t, 31) end
  def self.green(t);  wrap(t, 32) end
  def self.yellow(t); wrap(t, 33) end
  def self.blue(t);   wrap(t, 34) end
  def self.dim(t);    wrap(t, 90) end
end

# Result of probing a single candidate bucket name.
Result = Struct.new(:bucket, :status, :code, :region, :listable, keyword_init: true) do
  # status is one of: :public, :private, :redirect, :not_found, :error, :other
  def found?
    %i[public private redirect].include?(status)
  end

  def label
    case status
    when :public    then Color.green('PUBLIC (listable)')
    when :private   then Color.yellow('private (403)')
    when :redirect  then Color.blue("exists (region: #{region})")
    when :not_found then Color.dim('not found')
    when :error     then Color.dim('error')
    else Color.dim("other (#{code})")
    end
  end

  def to_h
    { bucket: bucket, status: status.to_s, code: code, region: region, listable: listable }
  end
end

# Probes a single bucket name against S3 and classifies the response.
class S3
  MAX_RETRIES = 3

  attr_reader :bucket

  def initialize(bucket, timeout: 5)
    @bucket  = bucket
    @timeout = timeout
    # Buckets containing a dot break TLS on the virtual-hosted endpoint
    # (the *.s3.amazonaws.com wildcard cert can't match a dotted host), so
    # fall back to the path-style endpoint for those names.
    @uri = if bucket.include?('.')
             URI.parse(format('https://s3.amazonaws.com/%s/', bucket))
           else
             URI.parse(format('https://%s.s3.amazonaws.com/', bucket))
           end
  end

  def probe
    classify(request)
  rescue StandardError
    # Network error / timeout is an error, never a "found" result.
    Result.new(bucket: bucket, status: :error, code: nil, region: nil, listable: false)
  end

  private

  def request
    attempts = 0
    begin
      attempts += 1
      http = Net::HTTP.new(@uri.host, @uri.port)
      http.use_ssl     = true
      http.open_timeout = @timeout
      http.read_timeout = @timeout
      response = http.get(@uri.request_uri)
      # 503 SlowDown: back off and retry a bounded number of times.
      if response.code.to_i == 503 && attempts < MAX_RETRIES
        sleep(0.3 * attempts)
        raise Net::HTTPFatalError.new('slowdown', response)
      end
      response
    rescue Net::HTTPFatalError
      retry if attempts < MAX_RETRIES
      raise
    end
  end

  def classify(response)
    code   = response.code.to_i
    region = response['x-amz-bucket-region']
    case code
    when 200
      Result.new(bucket: bucket, status: :public, code: code, region: region,
                 listable: response.body.to_s.include?('<ListBucketResult'))
    when 403
      Result.new(bucket: bucket, status: :private, code: code, region: region, listable: false)
    when 301, 307
      Result.new(bucket: bucket, status: :redirect, code: code, region: region, listable: false)
    when 404
      Result.new(bucket: bucket, status: :not_found, code: code, region: region, listable: false)
    else
      Result.new(bucket: bucket, status: :other, code: code, region: region, listable: false)
    end
  end
end

# Concurrently probes a list of candidate names with a pool of worker threads.
class Scanner
  # AWS bucket naming rules (simplified): 3-63 chars, lowercase letters,
  # digits, hyphens and dots; must start/end alphanumeric.
  VALID_NAME = /\A(?=.{3,63}\z)[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?\z/.freeze

  def initialize(list, threads: 20, timeout: 5, verbose: false)
    @list    = list.select { |w| w =~ VALID_NAME }
    @skipped = list.length - @list.length
    @threads = [threads, 1].max
    @timeout = timeout
    @verbose = verbose
  end

  def scan
    queue   = Queue.new
    @list.each { |w| queue << w }
    results = Queue.new
    total   = @list.length
    done    = 0
    found   = 0
    mutex   = Mutex.new

    workers = Array.new([@threads, total].min) do
      Thread.new do
        until queue.empty?
          word = queue.pop(true) rescue break
          result = S3.new(word, timeout: @timeout).probe
          mutex.synchronize do
            done += 1
            if result.found?
              found += 1
              results << result
              $stderr.print "\r#{' ' * 60}\r"
              puts "#{result.bucket} - #{result.label}"
            elsif @verbose
              $stderr.print "\r#{' ' * 60}\r"
              puts Color.dim("#{result.bucket} - #{result.label}")
            end
            progress(done, total, found)
          end
        end
      end
    end
    workers.each(&:join)
    $stderr.print "\r#{' ' * 60}\r"

    out = []
    out << results.pop until results.empty?
    out.sort_by(&:bucket)
  end

  private

  def progress(done, total, found)
    $stderr.print "\r#{Color.dim("[#{done}/#{total}] found: #{found}")}"
  end
end

# Builds candidate bucket names from a company name and a prefix wordlist.
class Wordlist
  ENVIRONMENTS = %w[dev development stage s3 staging prod production test qa uat].freeze
  SEPARATORS   = ['-', '.', '', '_'].freeze
  PERMUTATIONS = %i[permutation_raw permutation_envs permutation_host].freeze

  class << self
    def generate(common_prefix, prefix_wordlist)
      [].tap do |list|
        PERMUTATIONS.each do |permutation|
          list << send(permutation, common_prefix, prefix_wordlist)
        end
      end.flatten.uniq
    end

    def from_file(prefix, file)
      words = File.read(file).split("\n").map(&:strip).reject(&:empty?)
      generate(prefix, words)
    end

    def permutation_raw(common_prefix, _prefix_wordlist)
      common_prefix
    end

    def permutation_envs(common_prefix, prefix_wordlist)
      [].tap do |permutations|
        prefix_wordlist.each do |word|
          ENVIRONMENTS.each do |environment|
            ['%s-%s-%s', '%s-%s.%s', '%s-%s%s', '%s.%s-%s', '%s.%s.%s', '%s_%s_%s']
              .each do |bucket_format|
                permutations << format(bucket_format, common_prefix, word, environment)
              end
          end
        end
      end
    end

    def permutation_host(common_prefix, prefix_wordlist)
      [].tap do |permutations|
        prefix_wordlist.each do |word|
          SEPARATORS.each do |sep|
            permutations << "#{common_prefix}#{sep}#{word}"
            permutations << "#{word}#{sep}#{common_prefix}"
          end
        end
      end
    end
  end
end

# Writes results in the requested format to stdout or a file.
module Output
  def self.write(results, format:, path:, only_public:)
    results = results.select { |r| r.status == :public } if only_public
    io = path ? File.open(path, 'w') : $stdout
    begin
      case format
      when 'json' then io.puts(JSON.pretty_generate(results.map(&:to_h)))
      when 'csv'
        csv = CSV.generate do |c|
          c << %w[bucket status code region listable]
          results.each { |r| c << [r.bucket, r.status, r.code, r.region, r.listable] }
        end
        io.print(csv)
      else
        results.each { |r| io.puts("#{r.bucket} - #{r.label}") }
      end
    ensure
      io.close if path
    end
    $stderr.puts(Color.dim("#{results.length} result(s) written#{path ? " to #{path}" : ''}."))

    public_count = results.count { |r| r.status == :public }
    if public_count.positive?
      $stderr.puts(Color.dim("#{public_count} look publicly listable - see 'Checking your results' in the README to inspect them (e.g. aws s3 ls s3://<bucket>/ --no-sign-request)."))
    end
  end
end

def parse_options(argv)
  options = {
    threads: 20, timeout: 5, wordlist: nil, output: nil,
    format: 'text', only_public: false, verbose: false
  }
  here = File.dirname(File.expand_path(__FILE__))
  options[:wordlist] = File.join(here, 'common_bucket_prefixes.txt')

  parser = OptionParser.new do |o|
    o.banner = 'Usage: ruby lazys3.rb [options] <COMPANY>'
    o.on('-t', '--threads N', Integer, 'Worker threads (default 20)') { |v| options[:threads] = v }
    o.on('--timeout SECS', Float, 'Per-request timeout (default 5)')  { |v| options[:timeout] = v }
    o.on('-w', '--wordlist FILE', 'Prefix wordlist file')             { |v| options[:wordlist] = v }
    o.on('-o', '--output FILE', 'Write results to FILE')              { |v| options[:output] = v }
    o.on('-f', '--format FMT', %w[text json csv], 'text|json|csv (default text)') { |v| options[:format] = v }
    o.on('--only-public', 'Report only publicly listable buckets')   { options[:only_public] = true }
    o.on('-v', '--verbose', 'Show every candidate checked')          { options[:verbose] = true }
    o.on('-h', '--help', 'Show this help') { puts o; exit 0 }
  end
  parser.parse!(argv)

  if argv.empty?
    $stderr.puts parser
    exit 1
  end
  [argv.shift, options]
end

if $PROGRAM_NAME == __FILE__
  company, options = parse_options(ARGV)
  unless File.readable?(options[:wordlist])
    abort(Color.red("Wordlist not found: #{options[:wordlist]}"))
  end

  wordlist = Wordlist.from_file(company, options[:wordlist])
  $stderr.puts("Generated #{wordlist.length} candidates for '#{company}', scanning with #{options[:threads]} threads...")

  results = Scanner.new(
    wordlist, threads: options[:threads], timeout: options[:timeout], verbose: options[:verbose]
  ).scan

  Output.write(results, format: options[:format], path: options[:output], only_public: options[:only_public])
end
