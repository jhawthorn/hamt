# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/hamt"

# Tests that HAMT matches Ruby Hash semantics, driven mostly by differential
# fuzzing: run identical random operations against a model Hash and a HAMT and
# assert they never disagree.
class TestHAMTSemantics < Minitest::Test
  # ---- differential fuzzing ------------------------------------------------

  # Compare full contents the way Hash itself would: by key/value, order-free.
  def assert_matches(model, hamt)
    assert_equal model.size, hamt.size, "size"
    assert_equal model.empty?, hamt.empty?, "empty?"
    assert_equal model.to_h, hamt.to_h, "to_h"
    assert_equal model.keys.sort_by(&:object_id), hamt.keys.sort_by(&:object_id), "keys"
    model.each do |k, v|
      assert hamt.key?(k), "key?(#{k.inspect})"
      assert_equal v, hamt[k], "[](#{k.inspect})"
      assert_equal v, hamt.fetch(k), "fetch(#{k.inspect})"
    end
  end

  # A small key range forces frequent overwrites, deletes, and re-inserts.
  def test_fuzz_small_keyspace
    20.times do |seed|
      rng = Random.new(seed)
      model = {}
      hamt = HAMT.new
      keys = (-20..20).to_a

      800.times do
        k = keys.sample(random: rng)
        case rng.rand(4)
        when 0, 1, 2
          v = rng.rand(10_000)
          model[k] = v
          hamt = hamt.set(k, v)
        else
          model.delete(k)
          hamt = hamt.delete(k)
        end

        assert_equal model.size, hamt.size
        probe = keys.sample(random: rng)
        assert_equal model.fetch(probe, :absent), hamt.fetch(probe, :absent)
      end

      assert_matches(model, hamt)
    end
  end

  # A large key range builds deep trees with lots of structure sharing.
  def test_fuzz_large_keyspace
    10.times do |seed|
      rng = Random.new(seed + 100)
      model = {}
      hamt = HAMT.new

      2000.times do
        k = rng.rand(1_000_000) - 500_000
        if rng.rand(3).zero? && !model.empty?
          k = model.keys.sample(random: rng)
          model.delete(k)
          hamt = hamt.delete(k)
        else
          v = rng.rand
          model[k] = v
          hamt = hamt.set(k, v)
        end
        assert_equal model.size, hamt.size
      end

      assert_matches(model, hamt)
    end
  end

  # Persistence: old versions must never be disturbed by later operations.
  def test_fuzz_persistence
    rng = Random.new(7)
    snapshots = [] # [hamt, frozen copy of the model at that point]
    model = {}
    hamt = HAMT.new

    300.times do
      k = rng.rand(50)
      if rng.rand(3).zero?
        model = model.dup.tap { |m| m.delete(k) }
        hamt = hamt.delete(k)
      else
        model = model.merge(k => rng.rand(100))
        hamt = hamt.set(k, rng.rand(100))
        # keep hamt/model in lockstep for the same value
        model[k] = hamt[k]
      end
      snapshots << [hamt, model] if rng.rand(10).zero?
    end

    snapshots.each do |snap_hamt, snap_model|
      assert_equal snap_model, snap_hamt.to_h
    end
  end

  # ---- keys that collide in the trie / share a full hash -------------------

  # Hash value is fully controllable, so we can force any trie shape.
  class HKey
    attr_reader :id, :h
    def initialize(id, h)
      @id = id
      @h = h
    end
    def hash = @h
    def eql?(other) = other.is_a?(HKey) && other.id == @id && other.h == @h
    alias == eql?
  end

  # Two keys whose hashes agree on many low bits but differ high force a deep
  # chain of single-child nodes before diverging.
  def test_deep_partial_collision
    a = HKey.new(:a, 0b00001)
    b = HKey.new(:b, 0b00001 | (1 << 40)) # differs only at bit 40 (~level 8)
    h = HAMT.new.set(a, 1).set(b, 2)
    assert_equal 2, h.size
    assert_equal 1, h[a]
    assert_equal 2, h[b]
    h = h.delete(a)
    assert_equal 1, h.size
    assert_nil h[a]
    assert_equal 2, h[b]
  end

  # Many keys sharing one hash all live in a single Collision bucket.
  def test_full_collision_bucket_matches_hash
    model = {}
    hamt = HAMT.new
    30.times do |i|
      k = HKey.new(i, 42) # identical hash for every key
      model[k] = i
      hamt = hamt.set(k, i)
    end
    assert_equal 30, hamt.size
    model.each { |k, v| assert_equal v, hamt[k] }

    # Delete half; the rest survive.
    model.keys.select { |k| k.id.even? }.each do |k|
      model.delete(k)
      hamt = hamt.delete(k)
    end
    assert_equal 15, hamt.size
    model.each { |k, v| assert_equal v, hamt[k] }
    assert_equal model.to_h, hamt.to_h
  end

  # A collision bucket coexisting with normally-hashed keys on the same path.
  def test_collision_bucket_mixed_with_plain_keys
    model = {}
    hamt = HAMT.new
    # Some full-collision keys, some deep-partial keys, some plain.
    keys = []
    keys += (0..10).map { |i| HKey.new(i, 7) }              # bucket
    keys += (0..10).map { |i| HKey.new(i, 7 | (i << 30)) }  # diverge high
    keys += (0..10).map { |i| HKey.new(i, i) }              # plain-ish
    keys.each_with_index do |k, i|
      model[k] = i
      hamt = hamt.set(k, i)
    end
    assert_equal model.size, hamt.size
    model.each { |k, v| assert_equal v, hamt[k] }
    assert_equal model.to_h, hamt.to_h

    # Persistent delete of every other key still matches.
    keys.each_slice(2) do |k, _|
      model.delete(k)
      hamt = hamt.delete(k)
    end
    assert_equal model.size, hamt.size
    assert_equal model.to_h, hamt.to_h
  end

  # ---- Hash edge-case semantics --------------------------------------------

  def test_nil_value_is_stored_not_absent
    h = HAMT.new.set(:a, nil)
    assert_nil h[:a]
    assert h.key?(:a)                 # present even though value is nil
    assert_nil h.fetch(:a, :def)        # stored nil, not the default
    assert_nil h.fetch(:a)            # fetch returns the stored nil
    assert_equal 1, h.size
    h = h.delete(:a)
    refute h.key?(:a)
    assert_equal 0, h.size
  end

  def test_false_value_is_stored_not_absent
    h = HAMT.new.set(:a, false)
    assert_equal false, h[:a]
    assert h.key?(:a)
    assert_equal false, h.fetch(:a, :def) # false, not the default
    assert_equal false, h.fetch(:a)
  end

  def test_nil_key
    h = HAMT.new.set(nil, 1)
    assert_equal 1, h[nil]
    assert h.key?(nil)
    h = h.set(nil, 2)
    assert_equal 2, h[nil]
    assert_equal 1, h.size
    h = h.delete(nil)
    refute h.key?(nil)
  end

  # Hash distinguishes 1 and 1.0 (eql? is false, hashes differ).
  def test_integer_and_float_are_distinct_keys
    h = HAMT.new.set(1, :int).set(1.0, :float)
    assert_equal 2, h.size
    assert_equal :int, h[1]
    assert_equal :float, h[1.0]
    # Mirror Ruby Hash exactly.
    ref = { 1 => :int, 1.0 => :float }
    assert_equal ref[1], h[1]
    assert_equal ref[1.0], h[1.0]
    assert_equal ref.size, h.size
  end

  def test_symbol_and_string_are_distinct_keys
    h = HAMT.new.set(:a, 1).set("a", 2)
    assert_equal 2, h.size
    assert_equal 1, h[:a]
    assert_equal 2, h["a"]
  end

  # Equal-but-not-identical string keys hit the same slot.
  def test_string_key_value_equality
    h = HAMT.new.set("key", 1)
    assert_equal 1, h["key"]
    assert_equal 1, h["k" + "ey"]
    h = h.set("k" + "ey", 2) # overwrite via a different object
    assert_equal 2, h["key"]
    assert_equal 1, h.size
  end

  # On overwrite, Hash keeps the ORIGINAL key object; so should HAMT.
  def test_overwrite_preserves_original_key_object
    first = +"key"
    h = HAMT.new.set(first, 1)
    h = h.set(+"key", 2) # eql? but a different object
    stored_key = h.keys.first
    assert_same first, stored_key
    assert_equal 2, h[first]
  end

  def test_fetch_semantics
    h = HAMT.new.set(:a, 1)
    assert_equal 1, h.fetch(:a)
    assert_equal :d, h.fetch(:missing, :d)
    assert_equal 99, h.fetch(:missing) { 99 }
    assert_equal :missing, (h.fetch(:missing) { |k| k }) # block gets the key
    err = assert_raises(KeyError) { h.fetch(:missing) }
    assert_match(/key not found/, err.message)
  end

  def test_fetch_returns_stored_falsey_values
    h = HAMT.new.set(:n, nil).set(:f, false)
    assert_nil h.fetch(:n)             # not the "absent" path
    assert_equal false, h.fetch(:f)
    assert_nil h.fetch(:n, :default)   # stored nil wins over the default
    assert_equal false, h.fetch(:f, :default)
    # A missing key still falls through to default / block / raise.
    assert_equal :default, h.fetch(:missing, :default)
    assert_raises(KeyError) { h.fetch(:missing) }
  end

  def test_fetch_matches_hash_across_fuzz
    rng = Random.new(11)
    model = {}
    hamt = HAMT.new
    200.times do
      k = rng.rand(30)
      model[k] = rng.rand(100)
      hamt = hamt.set(k, model[k])
    end
    (0..40).each do |k|
      # no-default form: both return value or both raise
      if model.key?(k)
        assert_equal model.fetch(k), hamt.fetch(k)
      else
        assert_raises(KeyError) { hamt.fetch(k) }
      end
      # default form and block form
      assert_equal model.fetch(k, :dflt), hamt.fetch(k, :dflt)
      assert_equal model.fetch(k) { |x| x * 10 }, hamt.fetch(k) { |x| x * 10 }
    end
  end

  def test_empty_hamt_semantics
    h = HAMT.new
    assert h.empty?
    assert_equal 0, h.size
    assert_nil h[:x]
    assert_equal :d, h.fetch(:x, :d)
    refute h.key?(:x)
    assert_equal({}, h.to_h)
    assert_equal [], h.keys
    assert_equal [], h.values
    assert_equal 0, h.each.size # sized enumerator
    assert_equal [], h.each.to_a
  end

  def test_delete_missing_and_from_empty_return_self
    e = HAMT.new
    assert_same e, e.delete(:anything)
    h = HAMT.new.set(:a, 1)
    assert_same h, h.delete(:b)
  end

  def test_set_identical_value_returns_self
    h = HAMT.new.set(:a, 1).set(:b, 2)
    assert_same h, h.set(:a, 1) # same object value
    v = +"x"
    h2 = h.set(:c, v)
    assert_same h2, h2.set(:c, v)
    refute_same h2, h2.set(:c, +"x") # equal but not identical -> new node
  end

  # == compares keys by eql? and values by ==, order-independently.
  def test_equality_semantics
    a = HAMT[x: 1, y: 2, z: 3]
    b = [[:z, 3], [:y, 2], [:x, 1]].reduce(HAMT.new) { |h, (k, v)| h.set(k, v) }
    assert_equal a, b
    refute_equal a, HAMT[x: 1, y: 2]           # fewer keys
    refute_equal a, HAMT[x: 1, y: 2, z: 4]     # different value
    refute_equal a, HAMT[x: 1, y: 2, w: 3]     # different key
    refute_equal a, { x: 1, y: 2, z: 3 }       # not a HAMT
    # values compared with ==, so 3 == 3.0
    assert_equal HAMT[a: 3], HAMT[a: 3.0]
  end

  def test_merge_matches_hash
    a = HAMT[a: 1, b: 2, c: 3]
    b = a.merge(b: 20, d: 40)
    assert_equal({ a: 1, b: 20, c: 3, d: 40 }, b.to_h) # later wins
    assert_equal({ a: 1, b: 2, c: 3 }, a.to_h)         # original untouched
    assert_equal({ a: 1, b: 2, c: 3 }, a.merge({}).to_h)
    assert_equal({}, HAMT.new.merge({}).to_h)
  end

  def test_merge_from_a_hamt_source
    a = HAMT[a: 1, b: 2]
    b = HAMT[b: 20, c: 30]
    assert_equal({ a: 1, b: 20, c: 30 }, a.merge(b).to_h)
  end

  # Hash#merge takes several arguments, applied left to right.
  def test_merge_multiple_arguments
    base = HAMT[a: 1]
    merged = base.merge({ b: 2 }, { c: 3, a: 10 }, HAMT[d: 4])
    ref = { a: 1 }.merge({ b: 2 }, { c: 3, a: 10 }, { d: 4 })
    assert_equal ref, merged.to_h
    assert_equal({ a: 10, b: 2, c: 3, d: 4 }, merged.to_h)
    assert_equal({ a: 1 }, base.to_h) # original untouched
  end

  # Hash#merge with a block resolves conflicts as block(key, old, new).
  def test_merge_with_conflict_block
    a = HAMT[a: 1, b: 2, c: 3]
    other = { b: 20, c: 30, d: 40 }
    seen = []
    merged = a.merge(other) do |key, old, new|
      seen << [key, old, new]
      old + new
    end
    ref = { a: 1, b: 2, c: 3 }.merge(other) { |_k, o, n| o + n }
    assert_equal ref, merged.to_h
    assert_equal({ a: 1, b: 22, c: 33, d: 40 }, merged.to_h)
    # Block invoked only for the colliding keys, with (key, old, new).
    assert_equal [[:b, 2, 20], [:c, 3, 30]].sort, seen.sort
  end

  # The block sees conflicts accumulated across multiple arguments too.
  def test_merge_multiple_args_with_block
    result = HAMT[x: 1].merge({ x: 2 }, { x: 3 }) { |_k, old, new| old + new }
    ref = { x: 1 }.merge({ x: 2 }, { x: 3 }) { |_k, old, new| old + new }
    assert_equal ref, result.to_h
    assert_equal({ x: 6 }, result.to_h) # 1+2 then 3+3
  end

  def test_merge_matches_hash_across_fuzz
    rng = Random.new(21)
    10.times do
      base_pairs = Array.new(rng.rand(30)) { [rng.rand(20), rng.rand(100)] }
      other_pairs = Array.new(rng.rand(30)) { [rng.rand(20), rng.rand(100)] }
      model = base_pairs.to_h
      hamt = HAMT[base_pairs]
      other = other_pairs.to_h

      assert_equal model.merge(other), hamt.merge(other).to_h
      assert_equal(
        model.merge(other) { |_k, o, n| o - n },
        hamt.merge(other) { |_k, o, n| o - n }.to_h
      )
    end
  end

  # Building from scratch matches a Hash built the same way, whatever the size.
  def test_bulk_build_matches_hash
    [0, 1, 2, 33, 100, 1000].each do |n|
      pairs = (0...n).map { |i| [i, i * i] }
      model = pairs.to_h
      hamt = HAMT[pairs]
      assert_equal n, hamt.size
      assert_equal model, hamt.to_h
      assert_equal model.keys.sort, hamt.keys.sort
      assert_equal model.values.sort, hamt.values.sort
    end
  end

  # Insert everything then delete everything, in shuffled orders, ends empty.
  def test_insert_all_then_delete_all
    5.times do |seed|
      rng = Random.new(seed + 300)
      keys = (0...500).to_a.shuffle(random: rng)
      hamt = keys.reduce(HAMT.new) { |h, k| h.set(k, k) }
      assert_equal 500, hamt.size
      keys.shuffle(random: rng).each { |k| hamt = hamt.delete(k) }
      assert hamt.empty?
      assert_equal 0, hamt.size
      assert_equal({}, hamt.to_h)
    end
  end

  def test_negative_and_zero_hash_keys
    # Objects with negative / zero hashes exercise sign-extended shifts.
    keys = [-1, -2, -3, 0, -(2**40), 2**40]
    model = {}
    hamt = HAMT.new
    keys.each_with_index { |k, i| model[k] = i; hamt = hamt.set(k, i) }
    assert_equal model.to_h, hamt.to_h
    model.each { |k, v| assert_equal v, hamt[k] }
  end

  def test_frozen_and_immutable
    h = HAMT.new.set(:a, 1)
    assert h.frozen?
    h2 = h.set(:b, 2)
    assert_nil h[:b]      # original unchanged
    assert_equal 1, h.size
    assert_equal 2, h2.size
  end
end
