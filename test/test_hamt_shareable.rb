# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/hamt"

class TestHAMTShareable < Minitest::Test
  class SKey
    attr_reader :id, :h
    def initialize(id, h)
      @id = id
      @h = h
      freeze
    end
    def hash = @h
    def eql?(other) = other.is_a?(SKey) && other.id == @id && other.h == @h
    alias == eql?
  end

  def test_empty
    assert Ractor.shareable?(HAMT.new)
  end

  def test_set_and_delete
    h = HAMT.new
    1000.times { |i| h = h.set(i, i) }
    assert Ractor.shareable?(h)
    500.times { |i| h = h.delete(i * 2) }
    assert Ractor.shareable?(h)
  end

  def test_collisions
    h = HAMT.new
    10.times { |i| h = h.set(SKey.new(i, 42), i) }
    10.times { |i| h = h.set(SKey.new(i, 42 | (i << 30)), i) }
    assert Ractor.shareable?(h)
    assert Ractor.shareable?(h.delete(SKey.new(0, 42)))
  end
end
