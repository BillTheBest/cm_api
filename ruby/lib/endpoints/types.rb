#!/usr/bin/env ruby
# encoding: UTF-8
#
# Copyright © 2016 Cask Data, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

require 'json'
require 'date'

# Ruby port note: Custom attr_accessor to run _check_attr before setting any attribute
# This replaces the __setattr__ override in the Python version
class Class
  def attr_writer_with_validation(*args)
    args.each do |arg|
      arg = arg.to_s

      # Custom setter to call _check_attr function before setting
      class_eval %{
        def #{arg}=(val)
          unless self.class.class_variable_get(:@@_WHITELIST).include? val
            _check_attr("#{arg}", false)
          end

          # set the value itself
          @#{arg}=val
        end
      }
    end
  end
end

module CmApi
  module Endpoints
    # Module for common types
    module Types
      # Encapsulates information about an attribute in the JSON encoding of the
      # object. It identifies properties of the attribute such as whether it's
      # read-only, its type, etc.
      class Attr
        DATE_TO_FMT = '%Y-%m-%dT%H:%M:%S.%6NZ'.freeze
        # Ruby's strptime doesn't support %6N microseconds. When deserializing we store 9 digits instead
        DATE_FROM_FMT = '%Y-%m-%dT%H:%M:%S.%NZ'.freeze

        def initialize(atype = nil, rw = true, is_api_list = false)
          @_atype = atype
          @_is_api_list = is_api_list
          @rw = rw
        end

        # Ruby port note: Renamed from the python version's "to_json" to not conflict with json gem
        # Returns the JSON encoding of the given attribute value.

        # If the value has a 'to_json_dict' object, that method is called. Otherwise,
        # the following values are returned for each input type:
        #  - datetime.datetime: string with the API representation of a date.
        #  - dictionary: if 'atype' is ApiConfig, a list of ApiConfig objects.
        #  - python list: python list (or ApiList) with JSON encoding of items
        #  - the raw value otherwise
        def attr_to_json(value, preserve_ro)
          if value.respond_to? 'to_json_dict'
            return value.to_json_dict(preserve_ro)
          elsif value.is_a?(Hash) && @_atype == ApiConfig
            return config_to_api_list(value)
          elsif value.is_a?(DateTime)
            return value.strftime(DATE_TO_FMT)
          elsif value.is_a?(Array) # TODO: any difference from python Tuple?
            return ApiList.new(value).to_json_dict if @_is_api_list
            res = []
            value.each do |x|
              res << attr_to_json(x, preserve_ro)
            end
            return res
          else
            return value
          end
        end

        # Ruby port note: Renamed from the python version's "from_json" for consistency with attr_to_json
        # Parses the given JSON value into an appropriate python object.

        # This means:
        # - a datetime.datetime if 'atype' is datetime.datetime
        # - a converted config dictionary or config list if 'atype' is ApiConfig
        # - if the attr is an API list, an ApiList with instances of 'atype'
        # - an instance of 'atype' if it has a 'from_json_dict' method
        # - a python list with decoded versions of the member objects if the input
        #   is a python list.
        # - the raw value otherwise
        def attr_from_json(resource_root, data)
          return nil if data.nil?

          if @_atype == DateTime
            return DateTime.strptime(data.to_s, DATE_FROM_FMT)
          elsif @_atype == ApiConfig
            # return hash for summary view, ApiList for full view. Detect from JSON data
            return {} unless data.key?('items')
            first = data['items'][0]
            return json_to_config(data, first.length == 2)
          elsif @_is_api_list
            return ApiList.from_json_dict(data, resource_root, @_atype)
          elsif data.is_a?(Array)
            res = []
            data.each do |x|
              res << attr_from_json(resource_root, x)
            end
            return res
          elsif @_atype.respond_to? 'from_json_dict'
            return @_atype.from_json_dict(data, resource_root)
          else
            return data
          end
        end
      end

      # Subclass that just defines the attribute as read-only.
      class ROAttr < Attr
        def initialize(atype = nil, is_api_list = false)
          super(atype, false, is_api_list)
        end
      end

      # Checks if the resource_root's API version it at least the given minimum
      # version.
      def check_api_version(resource_root, min_version)
        if resource_root.version < min_version
          raise "Api version #{min_version} is required but #{resource_root.version} is in use."
        end
      end

      # Generic function for calling a resource method and automatically dealing with
      # serialization of parameters and deserialization of return values.
      # Ruby Port note: renamed from the Python version's "call" to not conflict with Proc#call

      # @param method: method to call (must be bound to a resource;
      #                e.g., "resource_root.get").
      # @param path: the full path of the API method to call.
      # @param ret_type: return type of the call.
      # @param ret_is_list: whether the return type is an ApiList.
      # @param data: Optional data to send as payload to the call.
      # @param params: Optional query parameters for the call.
      # @param api_version: minimum API version for the call.
      def call_resource(method, path, ret_type, ret_is_list = false, data = nil, params = nil, api_version = 1)
        check_api_version(method.receiver, api_version)
        if !data.nil?
          data = Attr.new(nil, true, true).attr_to_json(data, false).to_json
          ret = method.call(path, params, data)
        else
          ret = method.call(path, params)
        end

        return if ret_type.nil?
        if ret_is_list
          return ApiList.from_json_dict(ret, method.receiver, ret_type)
        elsif ret.is_a?(Array)
          res = []
          ret.each do |x|
            res << ret_type.from_json_dict(x, method.receiver)
          end
          return res
        else
          return ret_type.from_json_dict(ret, method.receiver)
        end
      end

      # The BaseApiObject helps with (de)serialization from/to JSON.

      # The derived class has two ways of defining custom attributes:
      #  - Overwriting the '_ATTRIBUTES' field with the attribute dictionary
      #  - Override the _get_attributes() method, in case static initialization of
      #    the above field is not possible.

      # It's recommended that the _get_attributes() implementation do caching to
      # avoid computing the dictionary on every invocation.

      # All constructor arguments (aside from self and resource_root) must
      # be keywords arguments with default values (typically nil), or
      # from_json_dict() will not work.
      class BaseApiObject
        include ::CmApi::Endpoints::Types

        # @_ATTRIBUTES is not inherited by subclasses, but rather initialized in the constructor below
        @_ATTRIBUTES = {}
        # @@_WHITELIST is a global, shared among all subclasses. It should not be modified.
        @@_WHITELIST = %w(_resource_root _attributes)

        attr_reader :_resource_root

        # Returns a map of property names to attr instances (or nil for default
        # attribute behavior) describing the properties of the object.

        # By default, this method will return the class's _ATTRIBUTES field.
        # Classes can override this method to do custom initialization of the
        # attributes when needed.
        def _get_attributes
          self.class.instance_variable_get(:@_ATTRIBUTES)
        end

        # Initializes internal state and sets all known writable properties of the
        # object to None. Then initializes the properties given in the provided
        # attributes dictionary.

        # @param resource_root: API resource object.
        # @param args: optional dictionary of attributes to set. This should only
        #               contain r/w attributes.
        def initialize(resource_root, args = nil)
          args.reject! { |x, _v| [:resource_root, :self].include? x } if args

          @_resource_root = resource_root

          # Initialize @_ATTRIBUTES if subclass has not defined it
          self.class.instance_variable_set(:@_ATTRIBUTES, {}) unless self.class.instance_variable_get(:@_ATTRIBUTES)

          _get_attributes.each do |name, _attr|
            instance_variable_set("@#{name}", nil)
            # Create the (custom) attr_accessors
            self.class.send(:attr_reader, name)
            self.class.send(:attr_writer_with_validation, name)
          end
          _set_attrs(args, false, false) if args
        end

        # TODO: functions should be converted to hash arguments, as they are often called using named parameters in python
        # Sets all the attributes in the dictionary. Optionally, allows setting
        # read-only attributes (e.g. when deserializing from JSON) and skipping
        # JSON deserialization of values.
        def _set_attrs(attrs, allow_ro = false, from_json = true)
          attrs.each do |k, v|
            attr = _check_attr(k.to_s, allow_ro)
            v = attr.attr_from_json(@_resource_root, v) if attr && from_json
            instance_variable_set("@#{k}", v)
          end
        end

        def _check_attr(name, allow_ro)
          unless _get_attributes.key? name
            raise "Invalid property #{name} for class #{self.class.name}"
          end
          attr = _get_attributes[name]

          if !allow_ro && attr && attr.instance_variable_defined?('@rw') && !attr.instance_variable_get('@rw')
            raise "Attribute #{name} of class #{self.class.name} is read only."
          end
          attr
        end

        def _update(api_obj)
          unless api_obj.is_a?(self.class)
            raise "Class #{self.class} does not derive from #{api_obj.class}; cannot update attributes."
          end

          _get_attributes.keys.each do |name|
            begin
              val = api_obj.instance_variable_get("@#{name}")
              instance_variable_set("@#{name}", val)
            rescue
              puts "ignoring failed update for attr: #{name}"
            end
          end
        end

        def to_json_dict(preserve_ro = false)
          dic = {}
          _get_attributes.each do |name, attr|
            next if !preserve_ro && attr && attr.respond_to?('rw') && !attr.rw
            begin
              value = instance_variable_get("@#{name}")
              unless value.nil?
                dic[name] = if attr
                              attr.attr_to_json(value, preserve_ro)
                            else
                              value
                            end
              end
            rescue
              puts "ignoring some failed to_json_dict with #{name}"
            end
          end
          dic
        end

        def to_s
          name = _get_attributes.keys[0]
          value = instance_variable_get("@#{name}") || nil
          "#{self.class.name}: #{name} = #{value}"
        end

        def self.from_json_dict(dic, resource_root)
          obj = new(resource_root)
          obj._set_attrs(dic, true, true)
          obj
        end
      end

      # A specialization of BaseApiObject that provides some utility methods for
      # resources. This class allows easier serialization / deserialization of
      # parameters and return values.
      class BaseApiResource < BaseApiObject
        # Returns the minimum API version for this resource. Defaults to 1.
        def _api_version
          1
        end

        # Returns the path to the resource.

        # e.g., for a service 'foo' in cluster 'bar', this should return
        # '/clusters/bar/services/foo'.
        def _path
          raise NotImplementedError
        end

        # Raise an exception if the version of the api is less than the given version.
        def _require_min_api_version(version)
          actual_version = @_resource_root.version
          version = [version, _api_version].max
          if actual_version < version
            raise "API version #{version} is required but #{actual_version} is in use."
          end
        end

        # Invokes a command on the resource. Commands are expected to be under the
        # "commands/" sub-resource.
        def _cmd(command, data = nil, params = nil, api_version = 1)
          _post('commands/' + command, ApiCommand, false, data, params, api_version)
        end

        # Retrieves an ApiConfig list from the given relative path.
        def _get_config(rel_path, view, api_version = 1)
          _require_min_api_version(api_version)
          params = view && { 'view' => view } || nil
          resp = @_resource_root.get(_path + '/' + rel_path, params)
          json_to_config(resp, view == 'full')
        end

        def _update_config(rel_path, config, api_version = 1)
          _require_min_api_version(api_version)
          resp = @_resource_root.put(_path + '/' + rel_path, nil, config_to_json(config))
          json_to_config(resp, false)
        end

        def _delete(rel_path, ret_type, ret_is_list = false, params = nil, api_version = 1)
          _call(:delete, rel_path, ret_type, ret_is_list, nil, params, api_version)
        end

        def _get(rel_path, ret_type, ret_is_list = false, params = nil, api_version = 1)
          _call(:get, rel_path, ret_type, ret_is_list, nil, params, api_version)
        end

        def _post(rel_path, ret_type, ret_is_list = false, data = nil, params = nil, api_version = 1)
          _call(:post, rel_path, ret_type, ret_is_list, data, params, api_version)
        end

        def _put(rel_path, ret_type, ret_is_list = false, data = nil, params = nil, api_version = 1)
          _call(:put, rel_path, ret_type, ret_is_list, data, params, api_version)
        end

        def _call(method_name, rel_path, ret_type, ret_is_list = false, data = nil, params = nil, api_version = 1)
          path = _path
          path += '/' + rel_path if rel_path && !rel_path.empty?
          call_resource(@_resource_root.method(method_name), path, ret_type, ret_is_list, data, params, api_version)
        end
      end

      # A list of some api object
      class ApiList < BaseApiObject
        LIST_KEY = 'items'.freeze

        def initialize(objects, resource_root = nil, *args)
          super(resource_root, args)
          instance_variable_set('@objects', objects)
        end

        def to_s
          "<ApiList>(#{@objects.length}): [#{@objects.map(&:to_s).join(', ')}]"
        end

        def to_json_dict(preserve_ro = false)
          ret = super
          attr = Attr.new
          res = []
          @objects.each do |x|
            res << attr.attr_to_json(x, preserve_ro)
          end
          ret[LIST_KEY] = res
          ret
        end

        def length
          @objects.length
        end

        def each(&block)
          @objects.each(&block)
        end

        def [](i)
          @objects[i]
        end

        # TODO: python __getslice equivalent

        def self.from_json_dict(dic, resource_root, member_cls = nil)
          member_cls = instance_variable_get(:@_MEMBER_CLASS) if member_cls.nil?
          attr = Attr.new(member_cls)
          items = []

          if dic.key? LIST_KEY
            dic[LIST_KEY].each do |x|
              items << attr.attr_from_json(resource_root, x)
            end
          end
          ret = new(items)

          # Handle if class declares custom attributes
          if instance_variable_get(:@_ATTRIBUTES)
            if dic.key? LIST_KEY
              dic = dic.clone
              dic.delete(LIST_KEY)
            end
            ret._set_attrs(dic, true)
          end
          ret
        end
      end

      # Model for a host reference
      class ApiHostRef < BaseApiObject
        @_ATTRIBUTES = {
          'hostId' => nil
        }

        def initialize(resource_root, hostId = nil)
          # Ruby port note: must call super with a hash argument of all local variable names/values.
          # Possible alternative to generate this hash argument dynamically, similar to python locals():
          # method(__method__).parameters.map { |arg| arg[1] }.inject({}) { |h, a| h[a] = eval a.to_s; h}
          super(resource_root, { hostId: hostId })
        end

        def to_s
          "<ApiHostRef>: #{@hostId}"
        end
      end

      # Model for a service reference
      class ApiServiceRef < BaseApiObject
        @_ATTRIBUTES = {
          'clusterName' => nil,
          'serviceName' => nil,
          'peerName' => nil
        }

        def initialize(resource_root, serviceName = nil, clusterName = nil, peerName = nil)
          super(resource_root, { serviceName: serviceName, clusterName: clusterName, peerName: peerName })
        end
      end

      # Model for a cluster reference
      class ApiClusterRef < BaseApiObject
        @_ATTRIBUTES = {
          'clusterName' => nil
        }

        def initialize(resource_root, clusterName = nil)
          super(resource_root, { clusterName: clusterName })
        end
      end

      # Model for a role reference
      class ApiRoleRef < BaseApiObject
        @_ATTRIBUTES = {
          'clusterName' => nil,
          'serviceName' => nil,
          'roleName' => nil
        }

        def initialize(resource_root, serviceName = nil, roleName = nil, clusterName = nil)
          super(resource_root, { serviceName: serviceName, roleName: roleName, clusterName: clusterName })
        end
      end

      # Model for a role config group reference
      class ApiRoleConfigGroupRef < BaseApiObject
        @_ATTRIBUTES = {
          'roleConfigGroupName' => nil
        }

        def initialize(resource_root, roleConfigGroupName = nil)
          super(resource_root, { roleConfigGroupName: roleConfigGroupName })
        end
      end

      # Model for a command
      class ApiCommand < BaseApiObject
        SYNCHRONOUS_COMMAND_ID = -1

        def _get_attributes
          unless self.class.instance_variable_get(:@_ATTRIBUTES) &&
                 !self.class.instance_variable_get(:@_ATTRIBUTES).empty?
            attributes = {
              'id'            => ROAttr.new,
              'name'          => ROAttr.new,
              'startTime'     => ROAttr.new(DateTime),
              'endTime'       => ROAttr.new(DateTime),
              'active'        => ROAttr.new,
              'success'       => ROAttr.new,
              'resultMessage' => ROAttr.new,
              'clusterRef'    => ROAttr.new(ApiClusterRef),
              'serviceRef'    => ROAttr.new(ApiServiceRef),
              'roleRef'       => ROAttr.new(ApiRoleRef),
              'hostRef'       => ROAttr.new(ApiHostRef),
              'children'      => ROAttr.new(ApiCommand, true),
              'parent'        => ROAttr.new(ApiCommand),
              'resultDataUrl' => ROAttr.new,
              'canRetry'      => ROAttr.new
            }
            self.class.instance_variable_set(:@_ATTRIBUTES, attributes)
          end
          self.class.instance_variable_get(:@_ATTRIBUTES)
        end

        def to_s
          "<ApiCommand>: '#{@name}' (id: #{@id}; active: #{@active}; success: #{@success}"
        end

        def _path
          "/commands/#{@id}"
        end

        def fetch
          return self if @id == ApiCommand::SYNCHRONOUS_COMMAND_ID

          resp = @_resource_root.get(_path)
          ApiCommand.from_json_dict(resp, @_resource_root)
        end

        def wait(timeout = nil)
          return self if @id == ApiCommand::SYNCHRONOUS_COMMAND_ID

          sleep_sec = 5

          deadline = if timeout.nil?
                       nil
                     else
                       Time.now + timeout
                     end

          loop do
            cmd = fetch
            return cmd unless cmd.active

            if !deadline.nil?
              now = Time.now()
              return cmd if deadline < now
              sleep([sleep_sec, deadline - now].min)
            else
              sleep(sleep_sec)
            end
          end
        end

        def abort
          return self if @id == ApiCommand.SYNCHRONOUS_COMMAND_ID

          path = _path + '/abort'
          resp = @_resource_root.post(path)
          ApiCommand.from_json_dict(resp, @_resource_root)
        end

        def retry
          path = _path + '/retry'
          resp = @_resource_root.post(path)
          ApiCommand.from_json_dict(resp, @_resource_root)
        end
      end

      # Model for a bulk command list
      class ApiBulkCommandList < ApiList
        @_ATTRIBUTES = {
          'errors' => ROAttr.new
        }
        @_MEMBER_CLASS = ApiCommand
      end

      # Model for ApiCommand metadata
      class ApiCommandMetadata < BaseApiObject
        @_ATTRIBUTES = {
          'name' => ROAttr.new,
          'argSchema' => ROAttr.new
        }

        def initialize(resource_root)
          super(resource_root)
        end

        def to_s
          "<ApiCommandMetadata>: #{@name} (#{@argSchema})"
        end
      end

      #
      # Configuration helpers.
      #
      class ApiConfig < BaseApiObject
        @_ATTRIBUTES = {
          'name' => nil,
          'value' => nil,
          'required' => ROAttr.new,
          'default' => ROAttr.new,
          'displayName' => ROAttr.new,
          'description' => ROAttr.new,
          'relatedName' => ROAttr.new,
          'validationState' => ROAttr.new,
          'validationMessage' => ROAttr.new,
          'validationWarningsSuppressed' => ROAttr.new
        }

        def initialize(resource_root, name = nil, value = nil)
          super(resource_root, { name: name, value: value })
        end

        def to_s
          "<ApiConfig>: #{@name} = #{@value}"
        end
      end

      def config_to_api_list(dic)
        config = []
        dic.each do |k, v|
          config << { 'name' => k, 'value' => v }
        end
        { ApiList::LIST_KEY => config }
      end

      def config_to_json(dic)
        config_to_api_list(dic).to_json
      end

      def json_to_config(dic, full = false)
        config = {}
        dic['items'].each do |entry|
          k = entry['name']
          config[k] = if full
                        ApiConfig.from_json_dict(entry, nil)
                      else
                        entry['value']
                      end
        end
        config
      end
    end
  end
end
