# frozen_string_literal: true

require_relative "hamt/version"

# A persistent (immutable) Hash Array Mapped Trie.
#
# `set` and `delete` return a new HAMT that shares structure with the old one;
# nothing is ever mutated and every node is frozen. Keys are compared the way
# Ruby's Hash compares them: by #hash, then #eql?.
#
#   a = HAMT[x: 1]
#   b = a.set(:y, 2)
#   a[:y]  # => nil   (a is untouched)
#   b[:y]  # => 2
#
class HAMT
  include Enumerable

  BITS = 5            # 5 bits per level => 32-way branches
  MASK = (1 << BITS) - 1

  NOT_FOUND = Object.new
  private_constant :NOT_FOUND

  # In a key slot: the value slot holds a sub-node, not a value.
  SUBNODE = Object.new.freeze
  private_constant :SUBNODE

  # array packs two cells per filled slot: [key, value] or [SUBNODE, child].
  class Node
    attr_reader :bitmap, :array

    def initialize(bitmap, array)
      @bitmap = bitmap
      @array = array
      freeze
    end

    def get(key, hash, shift, default)
      bit = 1 << ((hash >> shift) & MASK)
      return default if (bitmap & bit).zero?
      i = 2 * index(bit)
      k = array[i]
      if SUBNODE.equal?(k)
        array[i + 1].get(key, hash, shift + BITS, default)
      elsif k.eql?(key)
        array[i + 1]
      else
        default
      end
    end

    def put(key, hash, shift, value, result)
      bit = 1 << ((hash >> shift) & MASK)
      i = 2 * index(bit)
      if (bitmap & bit).zero?
        result.count += 1
        Node.new(bitmap | bit, insert2(array, i, key, value))
      elsif SUBNODE.equal?(k = array[i])
        child = array[i + 1]
        new_child = child.put(key, hash, shift + BITS, value, result)
        new_child.equal?(child) ? self : Node.new(bitmap, store1(array, i + 1, new_child))
      elsif k.eql?(key)
        return self if array[i + 1].equal?(value)
        Node.new(bitmap, store1(array, i + 1, value))
      else
        # different key, same slot: push the existing pair down a level
        ev = array[i + 1]
        ehash = k.hash
        child =
          if ehash == hash
            result.count += 1
            Collision.new(hash, [k, ev, key, value].freeze)
          else
            sub = Node.new(1 << ((ehash >> (shift + BITS)) & MASK), [k, ev].freeze)
            sub.put(key, hash, shift + BITS, value, result)
          end
        Node.new(bitmap, store2(array, i, SUBNODE, child))
      end
    end

    def delete(key, hash, shift)
      bit = 1 << ((hash >> shift) & MASK)
      return self if (bitmap & bit).zero?
      i = 2 * index(bit)
      k = array[i]
      if SUBNODE.equal?(k)
        child = array[i + 1]
        new_child = child.delete(key, hash, shift + BITS)
        return self if new_child.equal?(child)
        if new_child.nil?
          rest = bitmap & ~bit
          rest.zero? ? nil : Node.new(rest, remove2(array, i))
        else
          Node.new(bitmap, store1(array, i + 1, new_child))
        end
      elsif k.eql?(key)
        rest = bitmap & ~bit
        rest.zero? ? nil : Node.new(rest, remove2(array, i))
      else
        self
      end
    end

    def each(&block)
      i = 0
      n = array.size
      while i < n
        k = array[i]
        if SUBNODE.equal?(k)
          array[i + 1].each(&block)
        else
          block.call([k, array[i + 1]])
        end
        i += 2
      end
    end

    private def index(bit) = popcount(bitmap & (bit - 1))

    private def popcount(int)
      n = 0
      while int != 0
        int &= int - 1
        n += 1
      end
      n
    end

    # [*a] beats Array#dup here: dup pays for rb_obj_dup_setup, splat is a
    # raw copy (see bench/array_copy.rb).
    private def insert2(a, i, x, y) = [*a].insert(i, x, y).freeze

    private def store1(a, i, x)
      b = [*a]
      b[i] = x
      b.freeze
    end

    private def store2(a, i, x, y)
      b = [*a]
      b[i] = x
      b[i + 1] = y
      b.freeze
    end

    private def remove2(a, i)
      b = [*a]
      b.slice!(i, 2)
      b.freeze
    end
  end
  private_constant :Node

  # Flat [k, v, k, v, ...] bucket for keys with a fully-equal hash.
  class Collision
    attr_reader :hash, :array

    def initialize(hash, array)
      @hash = hash
      @array = array
      freeze
    end

    def get(key, _hash, _shift, default)
      i = 0
      n = array.size
      while i < n
        return array[i + 1] if array[i].eql?(key)
        i += 2
      end
      default
    end

    def put(key, hash, shift, value, result)
      return split(shift).put(key, hash, shift, value, result) unless hash == self.hash
      i = 0
      n = array.size
      while i < n
        if array[i].eql?(key)
          return self if array[i + 1].equal?(value)
          b = [*array]
          b[i + 1] = value
          return Collision.new(hash, b.freeze)
        end
        i += 2
      end
      result.count += 1
      Collision.new(hash, ([*array] << key << value).freeze)
    end

    def delete(key, _hash, _shift)
      i = 0
      n = array.size
      while i < n
        if array[i].eql?(key)
          return nil if n == 2
          b = [*array]
          b.slice!(i, 2)
          return Collision.new(hash, b.freeze)
        end
        i += 2
      end
      self
    end

    def each
      i = 0
      n = array.size
      while i < n
        yield [array[i], array[i + 1]]
        i += 2
      end
    end

    private def split(shift) = Node.new(1 << ((hash >> shift) & MASK), [SUBNODE, self].freeze)
  end
  private_constant :Collision

  EMPTY_ROOT = Node.new(0, [].freeze)
  private_constant :EMPTY_ROOT

  def self.[](enum = [])
    enum.reduce(new) { |h, (k, v)| h.set(k, v) }
  end

  def initialize(root = EMPTY_ROOT, count = 0)
    @root = root
    @count = count
    freeze
  end

  attr_accessor :root, :count
  alias size count
  alias length count
  def empty? = @count.zero?

  def [](key)
    @root.get(key, key.hash, 0, nil)
  end

  def key?(key)
    !NOT_FOUND.equal?(@root.get(key, key.hash, 0, NOT_FOUND))
  end
  alias has_key? key?
  alias include? key?

  def fetch(key, default = NOT_FOUND)
    value = @root.get(key, key.hash, 0, NOT_FOUND)
    return value unless NOT_FOUND.equal?(value)
    return yield(key) if block_given?
    return default unless NOT_FOUND.equal?(default)
    raise KeyError, "key not found: #{key.inspect}"
  end

  def set(key, value)
    result = HAMT.allocate
    result.count = @count
    root = @root.put(key, key.hash, 0, value, result)
    return self if root.equal?(@root)
    result.root = root
    result.freeze
    result
  end
  alias store set
  alias put set

  def delete(key)
    root = @root.delete(key, key.hash, 0)
    return self if root.equal?(@root)
    HAMT.new(root || EMPTY_ROOT, @count - 1)
  end

  def each(&block)
    return enum_for(:each) { @count } unless block_given?
    @root.each(&block)
    self
  end

  def merge(*others)
    others.reduce(self) do |acc, other|
      other.reduce(acc) do |h, (k, v)|
        if block_given? && !NOT_FOUND.equal?(old = h.root.get(k, k.hash, 0, NOT_FOUND))
          h.set(k, yield(k, old, v))
        else
          h.set(k, v)
        end
      end
    end
  end
  def keys = map { |k, _| k }
  def values = map { |_, v| v }
  def to_h = each_with_object({}) { |(k, v), h| h[k] = v }

  def ==(other)
    other.is_a?(HAMT) && other.count == @count &&
      all? { |k, v| other.root.get(k, k.hash, 0, NOT_FOUND) == v }
  end

  def inspect = "HAMT[#{map { |k, v| "#{k.inspect}=>#{v.inspect}" }.join(', ')}]"
  alias to_s inspect
end
