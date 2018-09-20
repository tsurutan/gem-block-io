# coding: utf-8
lib = File.expand_path('../lib', __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require 'ci_block_io/version'

Gem::Specification.new do |spec|
  spec.name          = "ci_block_io"
  spec.version       = CiBlockIo::VERSION
  spec.authors       = ["Atsuhiro Tsuruta feat. Atif Nazir"]
  spec.email         = ["a.tsuruta@1-box.co.jp"]
  spec.summary       = %q{An easy to use Dogecoin, Bitcoin, Litecoin wallet API by Block.io. Sign up required at Block.io.}
  spec.description   = %q{This Ruby Gem is the official reference client for the Block.io payments API. To use this, you will need the Dogecoin, Bitcoin, or Litecoin API key(s) from Block.io. Go ahead, sign up :)}
  spec.homepage      = "https://block.io/api/simple/ruby"
  spec.license       = "MIT"

  spec.files         = `git ls-files -z`.split("\x0")
  spec.executables   = spec.files.grep(%r{^bin/}) { |f| File.basename(f) }
  spec.test_files    = spec.files.grep(%r{^(test|spec|features)/})
  spec.require_paths = ["lib"]

  spec.add_development_dependency "bundler", "~> 1.6"
  spec.add_development_dependency "rake", "~> 0"
  spec.add_runtime_dependency "ecdsa", "~> 1.2", '>= 1.2.0'
  spec.add_runtime_dependency "httpclient", "~> 2.8", '>= 2.8.0'
  spec.add_runtime_dependency "oj", "~> 3.3", '>= 3.3.5'
  spec.add_runtime_dependency "pbkdf2-ruby", '~> 0.2', '>= 0.2.1'
end
