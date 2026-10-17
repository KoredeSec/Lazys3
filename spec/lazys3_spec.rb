# frozen_string_literal: true

require_relative '../lazys3'

RSpec.describe Wordlist do
  it 'includes the raw company name' do
    list = Wordlist.generate('acme', %w[assets])
    expect(list).to include('acme')
  end

  it 'builds host and env permutations in both orders' do
    list = Wordlist.generate('acme', %w[assets])
    expect(list).to include('acme-assets', 'assets-acme', 'acme.assets', 'acme_assets')
    expect(list).to include('acme-assets-prod')
  end

  it 'de-duplicates candidates' do
    list = Wordlist.generate('acme', %w[acme])
    expect(list).to eq(list.uniq)
  end
end

RSpec.describe S3 do
  # Minimal stub standing in for a Net::HTTPResponse.
  FakeResponse = Struct.new(:code, :body, :headers) do
    def [](k); (headers || {})[k]; end
  end

  def classify(code, body: '', region: nil)
    s3 = S3.new('example', timeout: 1)
    headers = region ? { 'x-amz-bucket-region' => region } : {}
    s3.send(:classify, FakeResponse.new(code.to_s, body, headers))
  end

  it 'classifies a listable 200 as public' do
    r = classify(200, body: '<ListBucketResult>...</ListBucketResult>')
    expect(r.status).to eq(:public)
    expect(r.listable).to be(true)
    expect(r.found?).to be(true)
  end

  it 'classifies 403 as private but existing' do
    r = classify(403)
    expect(r.status).to eq(:private)
    expect(r.found?).to be(true)
  end

  it 'captures the region on a 301 redirect' do
    r = classify(301, region: 'eu-west-1')
    expect(r.status).to eq(:redirect)
    expect(r.region).to eq('eu-west-1')
  end

  it 'classifies 404 as not found' do
    r = classify(404)
    expect(r.status).to eq(:not_found)
    expect(r.found?).to be(false)
  end

  it 'reports network errors as :error, never as found (regression test)' do
    s3 = S3.new('example', timeout: 1)
    allow(s3).to receive(:request).and_raise(Timeout::Error)
    r = s3.probe
    expect(r.status).to eq(:error)
    expect(r.found?).to be(false)
  end
end

RSpec.describe Scanner do
  it 'skips candidates with invalid S3 names' do
    scanner = Scanner.new(['ok-bucket', 'Bad_UPPER', 'x'], threads: 1)
    expect(scanner.instance_variable_get(:@list)).to eq(['ok-bucket'])
  end
end
