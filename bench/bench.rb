# frozen_string_literal: true

# Uses jhawthorn's `ips` gem. Run with the gem on the load path:
#   ruby -I ~/src/ips/lib bench/bench.rb
$LOAD_PATH.unshift File.expand_path("~/src/ips/lib")
require "ips"
require_relative "../lib/hamt"

SIZES = [100, 1_000, 10_000, 100_000]

build_hamt = ->(keys) { keys.reduce(HAMT.new) { |h, k| h.set(k, k) } }
build_hash = ->(keys) { keys.each_with_object({}) { |k, h| h[k] = k } }

IPS.run(time: 1, warmup: 0.3) do |x|
  # Lookup: HAMT vs native Hash.
  x.sweep("HAMT#[]", SIZES) do |n, bench|
    hamt = build_hamt[(0...n).to_a]
    bench.call { hamt[0] }
  end
  x.sweep("Hash#[]", SIZES) do |n, bench|
    hash = build_hash[(0...n).to_a]
    bench.call { hash[0] }
  end

  # Persistent insert (overwrite): HAMT path-copy vs Hash full dup.
  x.sweep("HAMT#set", SIZES) do |n, bench|
    hamt = build_hamt[(0...n).to_a]
    bench.call { hamt.set(0, :x) }
  end
  x.sweep("Hash dup+set", SIZES) do |n, bench|
    hash = build_hash[(0...n).to_a]
    bench.call { hash.dup[0] = :x }
  end

  # Persistent delete: HAMT path-copy vs Hash full dup.
  x.sweep("HAMT#delete", SIZES) do |n, bench|
    hamt = build_hamt[(0...n).to_a]
    bench.call { hamt.delete(0) }
  end
  x.sweep("Hash dup+delete", SIZES) do |n, bench|
    hash = build_hash[(0...n).to_a]
    bench.call { hash.dup.delete(0) }
  end
end
