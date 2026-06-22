# frozen_string_literal: true

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

  # A bucket of key/value pairs sharing one full hash. Almost always holds a
  # single pair; only true hash collisions make it longer.
  Leaf = Struct.new(:hash, :pairs) do
    def get(key, _hash, _shift, default)
      pair = pairs.find { |k, _| k.eql?(key) }
      pair ? pair[1] : default
    end

    def put(key, hash, shift, value)
      return split(shift).put(key, hash, shift, value) unless hash == self.hash
      existing = pairs.find { |k, _| k.eql?(key) }
      return self if existing && existing[1].equal?(value) # unchanged: share
      kept = pairs.reject { |k, _| k.eql?(key) }
      Leaf.new(hash, (kept << [key, value]).freeze)
    end

    def delete(key, _hash, _shift)
      kept = pairs.reject { |k, _| k.eql?(key) }
      return self if kept.size == pairs.size # key wasn't here
      kept.empty? ? nil : Leaf.new(hash, kept.freeze)
    end

    def each(&block) = pairs.each(&block)

    # Wrap this leaf in a one-entry branch at the given level, so a key with a
    # different hash can be inserted alongside it.
    private def split(shift) = Node.new(1 << ((hash >> shift) & MASK), [self].freeze)
  end
  private_constant :Leaf

  # A sparse branch. `bitmap` marks which of the 32 slots are filled; `slots`
  # holds just those children (each a Leaf or a Node), packed densely.
  Node = Struct.new(:bitmap, :slots) do
    def get(key, hash, shift, default)
      bit = 1 << ((hash >> shift) & MASK)
      return default if (bitmap & bit).zero?
      slots[index(bit)].get(key, hash, shift + BITS, default)
    end

    def put(key, hash, shift, value)
      bit = 1 << ((hash >> shift) & MASK)
      i = index(bit)
      if (bitmap & bit).zero?
        Node.new(bitmap | bit, insert(slots, i, Leaf.new(hash, [[key, value]].freeze)))
      else
        child = slots[i].put(key, hash, shift + BITS, value)
        child.equal?(slots[i]) ? self : Node.new(bitmap, replace(slots, i, child))
      end
    end

    def delete(key, hash, shift)
      bit = 1 << ((hash >> shift) & MASK)
      return self if (bitmap & bit).zero?
      i = index(bit)
      child = slots[i].delete(key, hash, shift + BITS)
      return self if child.equal?(slots[i])

      if child.nil?
        rest = bitmap & ~bit
        rest.zero? ? nil : Node.new(rest, remove(slots, i))
      else
        Node.new(bitmap, replace(slots, i, child))
      end
    end

    def each(&block) = slots.each { |child| child.each(&block) }

    # Dense position of `bit` within the packed slots: count the set bits below it.
    private def index(bit) = (bitmap & (bit - 1)).to_s(2).count("1")
    private def insert(a, i, x)  = a.dup.insert(i, x).freeze
    private def replace(a, i, x) = a.dup.tap { |b| b[i] = x }.freeze
    private def remove(a, i)     = a.dup.tap { |b| b.delete_at(i) }.freeze
  end
  private_constant :Node

  # ---- public API --------------------------------------------------------

  # HAMT.new is empty; HAMT[a: 1, b: 2] (or HAMT[pairs]) seeds from an enumerable.
  def self.[](enum = [])
    enum.reduce(new) { |h, (k, v)| h.set(k, v) }
  end

  def initialize(root = nil, count = 0)
    @root = root
    @count = count
    freeze
  end

  attr_reader :count
  alias size count
  alias length count
  def empty? = @count.zero?

  def get(key, default = nil)
    @root ? @root.get(key, key.hash, 0, default) : default
  end
  alias [] get

  def key?(key)
    return false unless @root
    !@root.get(key, key.hash, 0, NOT_FOUND).equal?(NOT_FOUND)
  end
  alias has_key? key?
  alias include? key?

  def fetch(key, *default)
    value = @root ? @root.get(key, key.hash, 0, NOT_FOUND) : NOT_FOUND
    return value unless value.equal?(NOT_FOUND)
    return yield(key) if block_given?
    return default.first unless default.empty?
    raise KeyError, "key not found: #{key.inspect}"
  end

  def set(key, value)
    hash = key.hash
    root = @root ? @root.put(key, hash, 0, value) : Leaf.new(hash, [[key, value]].freeze)
    return self if root.equal?(@root)
    HAMT.new(root, key?(key) ? @count : @count + 1)
  end
  alias store set
  alias put set

  def delete(key)
    return self unless @root
    root = @root.delete(key, key.hash, 0)
    root.equal?(@root) ? self : HAMT.new(root, @count - 1)
  end

  def each(&block)
    return enum_for(:each) { @count } unless block_given?
    @root&.each(&block)
    self
  end

  def merge(other) = other.reduce(self) { |h, (k, v)| h.set(k, v) }
  def keys = map { |k, _| k }
  def values = map { |_, v| v }
  def to_h = each_with_object({}) { |(k, v), h| h[k] = v }

  def ==(other)
    other.is_a?(HAMT) && other.count == @count &&
      all? { |k, v| other.get(k, NOT_FOUND) == v }
  end

  def inspect = "HAMT[#{map { |k, v| "#{k.inspect}=>#{v.inspect}" }.join(', ')}]"
  alias to_s inspect
end
