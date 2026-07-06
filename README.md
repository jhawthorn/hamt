# HAMT

A persistent (immutable) Hash Array Mapped Trie for Ruby.

`set` and `delete` return a new HAMT that shares structure with the old one;
nothing is ever mutated. Keys are compared the way Ruby's Hash compares them:
by `#hash`, then `#eql?`.

```ruby
a = HAMT[x: 1]
b = a.set(:y, 2)
a[:y]  # => nil   (a is untouched)
b[:y]  # => 2
```

## Installation

```
gem install hamt
```

## License

MIT
