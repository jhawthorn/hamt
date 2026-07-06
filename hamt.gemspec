# frozen_string_literal: true

require_relative "lib/hamt/version"

Gem::Specification.new do |spec|
  spec.name = "hamt"
  spec.version = HAMT::VERSION
  spec.authors = ["John Hawthorn"]
  spec.email = ["john@hawthorn.email"]

  spec.summary = "A persistent (immutable) Hash Array Mapped Trie"
  spec.description = spec.summary
  spec.homepage = "https://github.com/jhawthorn/hamt"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage

  spec.files = Dir["lib/**/*.rb"] + %w[README.md LICENSE.txt]
  spec.require_paths = ["lib"]
end
