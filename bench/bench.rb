# frozen_string_literal: true

require_relative "../lib/hamt"

# Run the block repeatedly, doubling the count until it's been timed for at
# least 0.1s, then return nanoseconds per call. Auto-scaling means cheap ops
# (HAMT, O(log n)) and expensive ones (Hash#dup, O(n)) both get a stable number
# without hand-tuning iteration counts.
def ns_per_call
  iters = 1
  loop do
    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    iters.times { yield }
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
    return elapsed / iters * 1e9 if elapsed >= 0.1
    iters *= 2
  end
end

SIZES = [100, 1_000, 10_000, 100_000]

SIZES.each do |n|
  keys = (0...n).to_a
  k    = keys.first
  hamt = keys.reduce(HAMT.new) { |h, x| h.set(x, x) }
  hash = keys.each_with_object({}) { |x, h| h[x] = x }

  # build/get are reported per element; set/delete are a single op.
  rows = {
    "HAMT" => [
      ns_per_call { keys.reduce(HAMT.new) { |h, x| h.set(x, x) } } / n,
      ns_per_call { keys.each { |x| hamt[x] } } / n,
      ns_per_call { hamt.set(k, :x) },
      ns_per_call { hamt.delete(k) },
    ],
    "Hash (dup)" => [
      ns_per_call { keys.each_with_object({}) { |x, h| h[x] = x } } / n,
      ns_per_call { keys.each { |x| hash[x] } } / n,
      ns_per_call { hash.dup.tap { |h| h[k] = :x } },
      ns_per_call { hash.dup.tap { |h| h.delete(k) } },
    ],
  }

  puts "n = #{n}  (ns per op)"
  rows.each do |name, (build, get, set, del)|
    puts format("  %-11s build %8.0f  get %8.0f  set %8.0f  delete %8.0f",
                name, build, get, set, del)
  end
  puts
end
