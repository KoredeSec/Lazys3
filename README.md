# lazys3

A Ruby script to bruteforce AWS S3 bucket names using permutations of a company
name and a prefix wordlist.

> For authorized security testing, bug-bounty, and research use only. Only probe
> assets you have permission to test.

## About this fork

This is an enhanced fork of [**nahamsec/lazys3**](https://github.com/nahamsec/lazys3),
originally written by [Ben Sadeghipour (nahamsec)](http://twitter.com/nahamsec)
and [Jobert Abma](http://twitter.com/JobertAbma). All credit for the original
idea and tool goes to them — this fork keeps their approach and builds on it.

The original is a compact, single-threaded script that does one job well: take a
company name, generate name permutations, and check each one over HTTP for a
found/not-found response. This fork keeps that core idea and extends it for
larger, real-world engagements. See [Why these features](#why-these-features)
for the reasoning behind each change.

## Usage

```
$ ruby lazys3.rb [options] <COMPANY>
```

Simple case:

```
$ ruby lazys3.rb mycompany
```

### Options

| Flag | Description | Default |
|------|-------------|---------|
| `-t`, `--threads N` | Number of worker threads | `20` |
| `--timeout SECS` | Per-request timeout | `5` |
| `-w`, `--wordlist FILE` | Prefix wordlist | `common_bucket_prefixes.txt` |
| `-o`, `--output FILE` | Write results to FILE | stdout |
| `-f`, `--format FMT` | `text`, `json`, or `csv` | `text` |
| `--only-public` | Report only publicly listable buckets | off |
| `-v`, `--verbose` | Show every candidate checked | off |
| `-h`, `--help` | Show help | |

### Examples

```
# 40 threads, JSON output to a file
$ ruby lazys3.rb -t 40 -f json -o results.json mycompany

# Only report buckets that are publicly listable
$ ruby lazys3.rb --only-public mycompany

# Custom wordlist, CSV to stdout
$ ruby lazys3.rb -w my_prefixes.txt -f csv mycompany
```

## Why these features

Each addition in this fork solves a concrete limitation I hit when using the
original against real scopes:

- **Concurrent scanning (thread pool).** A thorough wordlist produces thousands
  of candidate names, and checking them one at a time is slow enough to
  discourage running a full list. A bounded thread pool cuts a scan from minutes
  to seconds without hammering the endpoint uncontrollably.
- **HTTPS instead of HTTP.** Probing over plaintext is both less accurate against
  modern S3 endpoints and leaks the names being tested on the wire. HTTPS is the
  correct default today.
- **Result classification instead of found/not-found.** "Exists" is not the
  interesting signal — *how exposed* a bucket is matters. Separating public
  (listable), private (`403`), and region-redirect (`301`/`307`) tells you what
  to act on instead of leaving you to re-check everything by hand.
- **Fixed timeout false-positives.** In the original flow a network timeout could
  be read as a hit. Timeouts are now classified as `error` and never reported as
  a found bucket, so the output is something you can trust.
- **Path-style fallback for dotted names.** Dotted bucket names break TLS
  hostname matching on the virtual-hosted endpoint; probing them path-style
  avoids silently missing valid buckets.
- **Structured output (JSON/CSV).** Engagements need results you can filter,
  diff, and feed into other tooling (`jq`, spreadsheets, reports). A CLI with
  machine-readable output makes lazys3 a pipeline step rather than a one-off.
- **OptionParser CLI + expanded wordlist/permutations.** Real targets need tuning
  (threads, timeout, custom wordlists) and broader coverage than the built-in
  defaults gave.
- **RSpec test suite.** The classification logic is the part most likely to
  regress; offline, stubbed tests keep it honest as the tool changes.

## Result classification

Each candidate is classified instead of a simple found/not-found:

- **PUBLIC (listable)** — `200`, bucket contents are publicly listable.
- **private (403)** — bucket exists but access is denied.
- **exists (region: …)** — `301`/`307` redirect; the bucket exists in another region.
- **not found** — `404`, no such bucket.
- **error** — network/timeout error (never reported as a found bucket).

Dotted bucket names are probed via the path-style endpoint to avoid TLS hostname
mismatches on the virtual-hosted endpoint.

## Checking your results

lazys3 reports that a bucket **exists** and how open it looked at probe time — it
does not inspect contents. Use the JSON/CSV output to pull the exact names and
regions, then follow up on anything in scope for your engagement.

Filter the output down to what you care about:

```
$ ruby lazys3.rb -f json -o results.json mycompany

# Just the publicly listable buckets
$ jq -r '.[] | select(.status=="public") | .bucket' results.json

# Everything that exists, with status and region
$ jq -r '.[] | .bucket + "  " + .status + "  " + (.region // "?")' results.json
```

What each status tells you and where to look next:

| Status | Meaning | Next step |
|--------|---------|-----------|
| `public` | Contents are world-listable (`200` + `ListBucketResult`) | List the keys to see what's exposed (below). |
| `private` | Bucket exists, anonymous listing denied (`403`) | Note it as existing; confirm ownership and whether it's in scope. |
| `redirect` | Exists in another region (`301`/`307`) | Re-check it against its real region (the `region` field). |
| `not_found` | No such bucket (`404`) | Nothing to do. |
| `error` | Network/timeout — **not** a finding | Re-run that name; transient failures happen under load. |

For a `public` bucket, list its contents to see what is actually exposed:

```
# Anonymous listing, no credentials used
$ aws s3 ls s3://<bucket>/ --no-sign-request --region <region>

# Same thing over plain HTTP — returns the object-key XML directly
$ curl -s "https://<bucket>.s3.<region>.amazonaws.com/" | head
```

Reminder: only inspect buckets you are authorized to test. A `private`/`403`
result means a bucket exists, not that you have any right to its contents.

## Development

```
$ bundle install
$ bundle exec rspec
```

Tests are offline — S3 responses are stubbed, so no network access is required.

## Credits

Original tool and concept by:

- [nahamsec](http://twitter.com/nahamsec) — https://github.com/nahamsec/lazys3
- [JobertAbma](http://twitter.com/JobertAbma)

Fork and v2.0 enhancements by [KoredeSec](https://github.com/KoredeSec).

## Changelog

- **2.0** — Concurrent scanning (thread pool); HTTPS; response classification
  (public / private / region-redirect / not-found); fixed timeout false-positive
  bug; path-style fallback for dotted names; OptionParser CLI; JSON/CSV output;
  expanded wordlist and permutations; RSpec test suite.
- **1.0** — Release (nahamsec / JobertAbma)
