# coding: utf-8
lib = File.expand_path('../lib', __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require 'transaction_reliability/version'

Gem::Specification.new do |spec|
  spec.name          = "transaction_reliability"
  spec.version       = TransactionReliability::VERSION
  spec.authors       = ["Robert Sanders"]
  spec.email         = ["robert@curioussquid.com"]
  spec.summary       = %q{Functions to wrap and retry a code block when the DB declares a serialization failure or deadlock.}
  # spec.description   = %q{TODO: Write a longer description. Optional.}
  spec.homepage      = "http://github.com/rsanders/transaction_reliability"
  spec.license       = "MIT"

  spec.files         = `git ls-files -z`.split("\x0")
  spec.executables   = spec.files.grep(%r{^bin/}) { |f| File.basename(f) }
  spec.test_files    = spec.files.grep(%r{^(test|spec|features|gemfiles|config)/})
  spec.require_paths = ["lib"]

  spec.add_dependency "activerecord", ">= 4.0.0"

  spec.add_development_dependency "pg", ">= 0.17.0"
  spec.add_development_dependency "bundler", "~> 1.7"
  spec.add_development_dependency "rake", "~> 10.0"
  spec.add_development_dependency "rspec", "~> 2.14.0"
  spec.add_development_dependency "simplecov"
  spec.add_development_dependency "wwtd"
end
