require 'inifile'
require 'singleton'

module HDeploy
  class Config

    attr_accessor :cfile
    attr_accessor :conf

    include Singleton

    # -------------------------------------------------------------------------
    def initialize
      # FIXME: add options to try manually set places...
      cfile_try = [
        'hdeploy.ini',
        '/opt/hdeploy/hdeploy.ini',
        '/etc/hdeploy/hdeploy.ini',
        '/etc/hdeploy.ini',
      ]
      cfile_try.insert(1,File.expand_path('~/hdeploy.ini')) if ENV.has_key?'HOME'


      cfile = false
      cfile_try.each do |f|
        if File.exists? f
          cfile = f
          break
        end
      end
      raise "unable to find conf file (tried #{cfile_try.join(',')})" unless cfile

      @cfile = cfile
      reload
    end

    # -------------------------------------------------------------------------
    def reload
      @conf = IniFile.load(@cfile).to_h
    end

  end
end
