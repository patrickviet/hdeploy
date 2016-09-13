require 'json'
require 'deep_merge'
require 'deep_clone'

module HDeploy
  class Conf

    @@instance = nil
    @@default_values = []

    attr_reader :file

    def initialize(file)
      @file = file
      reload
    end

    def self.instance(path = '/opt/hdeploy/etc/hdeploy.conf.json')
      @@instance ||= new(path)
    end

    # -------------------------------------------------------------------------

    def reload
      raise "unable to find conf file #{@file}" unless File.exists? @file
      
      st = File.stat(@file)
      raise "config file #{@file} must not be a symlink" if File.symlink?(@file)
      raise "config file #{@file} must be a regular file" unless st.file?
      raise "config file #{@file} must have uid 0" unless st.uid == 0 or Process.uid != 0
      raise "config file #{@file} must not allow group/others to write" unless sprintf("%o", st.mode) =~ /^100[46][04][04]/
      
      # Seems we have checked everything. Woohoo!
      @conf = JSON.parse(File.read(@file))
    end

    # -------------------------------------------------------------------------
    def [](k)
      @conf[k] 
    end
    
    # -------------------------------------------------------------------------
    def add_defaults(h)
      # This is pretty crappy code in that it loads stuff twice etc. But that way no re-implementing a variation of deep_merge for default stuff...
      @@default_values << h.__deep_clone__

      rebuild_conf = {}
      @@default_values.each do |defval|
        rebuild_conf.deep_merge!(defval)
      end

      @conf = rebuild_conf.deep_merge!(@conf)
    end
  end
end
