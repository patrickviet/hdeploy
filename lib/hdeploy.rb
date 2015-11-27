require 'hdeploy/config'
require 'hdeploy/cli'
require 'hdeploy/node'
require 'hdeploy/apiclient'

module HDeploy
  def HDeploy.where_is(f)
    File.expand_path "../#{f}", __FILE__
  end
end

