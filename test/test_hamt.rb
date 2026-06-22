# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/hamt"

class TestHAMT < Minitest::Test
  def test_empty
    h = HAMT.new
    assert_equal 0, h.size
    assert h.empty?
    assert_nil h[:missing]
    assert_equal :default, h.get(:missing, :default)
    refute h.key?(:missing)
  end

  def test_set_and_get
    h = HAMT.new.set(:a, 1).set(:b, 2).set(:c, 3)
    assert_equal 1, h[:a]
    assert_equal 2, h[:b]
    assert_equal 3, h[:c]
    assert_equal 3, h.size
    assert h.key?(:a)
  end

  def test_immutability
    h1 = HAMT.new.set(:a, 1)
    h2 = h1.set(:b, 2)
    assert_nil h1[:b]
    assert_equal 1, h1.size
    assert_equal 2, h2.size
    assert h1.frozen?
  end

  def test_overwrite_does_not_change_count
    h = HAMT.new.set(:a, 1).set(:a, 2)
    assert_equal 1, h.size
    assert_equal 2, h[:a]
  end

  def test_set_same_value_returns_self
    h1 = HAMT.new.set(:a, 1)
    h2 = h1.set(:a, 1)
    assert_same h1, h2
  end

  def test_delete
    h = HAMT.new.set(:a, 1).set(:b, 2)
    h2 = h.delete(:a)
    assert_nil h2[:a]
    assert_equal 2, h2[:b]
    assert_equal 1, h2.size
    # original untouched
    assert_equal 1, h[:a]
    assert_equal 2, h.size
  end

  def test_delete_missing_returns_self
    h = HAMT.new.set(:a, 1)
    assert_same h, h.delete(:nope)
  end

  def test_delete_all
    h = HAMT.new.set(:a, 1).set(:b, 2)
    h = h.delete(:a).delete(:b)
    assert h.empty?
    assert_nil h[:a]
  end

  def test_fetch
    h = HAMT.new.set(:a, 1)
    assert_equal 1, h.fetch(:a)
    assert_equal :d, h.fetch(:x, :d)
    assert_equal 99, h.fetch(:x) { 99 }
    assert_raises(KeyError) { h.fetch(:x) }
  end

  def test_each_and_enumerable
    pairs = { a: 1, b: 2, c: 3 }
    h = HAMT[pairs]
    assert_equal pairs, h.to_h
    assert_equal pairs, h.each_with_object({}) { |(k, v), acc| acc[k] = v }
    assert_equal [:a, :b, :c].sort, h.keys.sort
    assert_equal [1, 2, 3].sort, h.values.sort
  end

  def test_seed_from_hash_and_pairs
    assert_equal({ a: 1 }, HAMT[a: 1].to_h)
    assert_equal({ a: 1, b: 2 }, HAMT[[[:a, 1], [:b, 2]]].to_h)
  end

  def test_equality
    a = HAMT[a: 1, b: 2]
    b = HAMT[b: 2, a: 1]
    assert_equal a, b
    refute_equal a, HAMT[a: 1]
    refute_equal a, HAMT[a: 1, b: 3]
  end

  def test_merge
    a = HAMT[a: 1, b: 2]
    b = a.merge(b: 20, c: 30)
    assert_equal({ a: 1, b: 20, c: 30 }, b.to_h)
    assert_equal({ a: 1, b: 2 }, a.to_h) # original untouched
  end

  # Two keys whose hashes collide entirely -> all share one Leaf bucket.
  class FixedHash
    attr_reader :id
    def initialize(id) = @id = id
    def hash = 42
    def eql?(other) = other.is_a?(FixedHash) && other.id == id
    def ==(other) = eql?(other)
  end

  def test_full_hash_collision
    k1 = FixedHash.new(1)
    k2 = FixedHash.new(2)
    k3 = FixedHash.new(3)
    h = HAMT.new.set(k1, :one).set(k2, :two).set(k3, :three)
    assert_equal 3, h.size
    assert_equal :one, h[k1]
    assert_equal :two, h[k2]
    assert_equal :three, h[k3]

    h = h.delete(k2)
    assert_equal 2, h.size
    assert_nil h[k2]
    assert_equal :one, h[k1]
    assert_equal :three, h[k3]
  end

  # A full-collision bucket sharing a path with a differently-hashed key.
  def test_collision_then_diverging_key
    k1 = FixedHash.new(1)
    k2 = FixedHash.new(2)
    h = HAMT.new.set(k1, :one).set(k2, :two)
    # 42 in low 5 bits is 0b01010; pick a normal key and confirm coexistence
    h = h.set(:plain, :p)
    assert_equal :one, h[k1]
    assert_equal :two, h[k2]
    assert_equal :p, h[:plain]
    assert_equal 3, h.size
  end

  # Stress: many keys forces deep trees, splits, and collapses on delete.
  def test_stress_many_keys
    n = 5000
    h = HAMT.new
    n.times { |i| h = h.set(i, i * i) }
    assert_equal n, h.size
    n.times { |i| assert_equal i * i, h[i] }

    # Delete the evens, persistently.
    deleted = h
    (0...n).step(2) { |i| deleted = deleted.delete(i) }
    assert_equal n / 2, deleted.size
    (0...n).each do |i|
      if i.even?
        assert_nil deleted[i]
      else
        assert_equal i * i, deleted[i]
      end
    end
    # Original still complete.
    assert_equal n, h.size
  end

  def test_string_keys_use_value_equality
    h = HAMT.new.set("key", 1)
    assert_equal 1, h["key"]          # different object, eql? + same hash
    assert_equal 1, h["k" + "ey"]
  end

  def test_inspect
    h = HAMT[a: 1]
    assert_equal "HAMT[:a=>1]", h.inspect
  end
end
