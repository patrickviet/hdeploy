$:.push File.expand_path("../lib", __FILE__)
require 'hdeploy/version'

Gem::Specification.new do |s|
  s.name          = "hdeploy"
  s.version       = HDeploy::VERSION
  s.authors       = ["Patrick Viet"]
  s.email         = ["patrick.viet@gmail.com"]
  s.description   = %q{HDeploy tool}
  s.summary       = %q{no summary}
  s.homepage      = "https://github.com/hdeploy/hdeploy"

  s.files         = `git ls-files`.split($/)
  s.executables   = s.files.grep(%r{^bin/}).map{ |f| File.basename(f) }
  s.test_files    = s.files.grep(%r{^(test|spec|features)/})
  s.require_paths = ["lib"]

  s.add_runtime_dependency 'json',    '>= 1.7.7'
  s.add_runtime_dependency 'curb',    '>= 0.8.5'
  s.add_runtime_dependency 'sinatra', '>= 1.4.5'
  s.add_runtime_dependency 'inifile',   '>= 2.0.2'  
  s.add_runtime_dependency 'cassandra-driver',   '>= 2.0.1'
  s.add_runtime_dependency 'eventmachine', '>= 1.0.7'

  s.add_development_dependency 'pry'
end
