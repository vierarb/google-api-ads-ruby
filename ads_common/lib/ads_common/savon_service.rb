#!/usr/bin/ruby
#
# Author:: api.dklimkin@gmail.com (Danial Klimkin)
#
# Copyright:: Copyright 2011, Google Inc. All Rights Reserved.
#
# License:: Licensed under the Apache License, Version 2.0 (the "License");
#           you may not use this file except in compliance with the License.
#           You may obtain a copy of the License at
#
#           http://www.apache.org/licenses/LICENSE-2.0
#
#           Unless required by applicable law or agreed to in writing, software
#           distributed under the License is distributed on an "AS IS" BASIS,
#           WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or
#           implied.
#           See the License for the specific language governing permissions and
#           limitations under the License.
#
# Base class for all generated API services based on Savon backend.

gem 'savon', '= 0.9.2'
require 'savon'

module AdsCommon
  class SavonService
    # Default namespace name.
    DEFAULT_NAMESPACE = 'wsdl'

    attr_accessor :headerhandler
    attr_reader :api
    attr_reader :version
    attr_reader :namespace

    # Creates a new service.
    def initialize(api, endpoint, namespace, version)
      if self.class() == AdsCommon::SavonService
        raise NoMethodError, "Tried to instantiate an abstract class"
      end
      @api = api
      @version = version
      @namespace = namespace
      @headerhandler = []
      @client = Savon::Client.new do |wsdl|
        wsdl.namespace = namespace
        wsdl.endpoint = endpoint
      end
    end

    private

    # Returns ServiceRegistry for the current service. Has to be overriden.
    def get_service_registry()
      raise NoMethodError, "This methods needs to be overriden"
    end

    # Returns Module for the current service. Has to be overriden.
    def get_module()
      raise NoMethodError, "This methods needs to be overriden"
    end

    # Executes SOAP action specified as a string with given arguments.
    def execute_action(action_name, args)
      args = validate_args(action_name, args)
      response = execute_soap_request(action_name.to_sym, args)
      handle_errors(response)
      return extract_result(response, action_name)
    end

    # Executes the SOAP request with original SOAP name.
    def execute_soap_request(action, args)
      original_action_name =
          get_service_registry.get_method_signature(action)[:original_name]
      original_action_name = action if original_action_name.nil?
      response = @client.request(original_action_name) do |soap|
        set_headers(soap, args)
      end
      return response
    end

    # Validates input parameters to:
    # - add parameter names;
    # - resolve xsi:type where required;
    # - convert some native types to xml.
    def validate_args(action_name, args)
      validated_args = {}
      in_params = get_service_registry.get_method_signature(action_name)[:input]
      in_params.each_with_index do |in_param, index|
        key = in_param[:name]
        value = deep_copy(args[index])
        validated_args[key] = (value.nil?) ?
             nil : validate_arg(value, validated_args, key, in_param[:type])
      end
      return validated_args
    end

    # Validates method argument. Runs recursively if hash or array encountered.
    # Also handles some types that need special conversions.
    def validate_arg(arg, parent = nil, key = nil, field_type_name = nil)
      field_type = (field_type_name.nil?) ? nil :
          get_service_registry.get_type_signature(field_type_name)
      if field_type and field_type[:base]
        field_type[:fields] += implode_parent(field_type)
      end
      result = case arg
        when Hash then validate_hash_arg(arg, parent, key, field_type)
        when Array then arg.map do |item|
           validate_arg(item, parent, key, field_type_name)
          end
        when Time then time_to_xml_hash(arg)
        else arg
      end
      return result
    end

    # Validates hash argument recursively. Keeps tracking of correct place
    # for xsi:type and adds is when required.
    def validate_hash_arg(arg, parent = nil, key = nil, field_type = nil)
      xsi_type = arg.delete('xsi:type') || arg.delete(:xsi_type)
      if xsi_type
        if parent and key
          add_xsi_type(parent, key, xsi_type)
        else
          raise AdsCommon::Errors::ApiException.new(
              "Can't find correct position for xsi:type (%s) [%s], [%s]" %
                  [xsi_type, parent, key])
        end
      end
      # Non-default namespace should be used, overriding default.
      if field_type and field_type.include?(:ns)
        namespace = get_service_registry.get_namespace(field_type[:ns])
        add_attribute(parent, prefix_key(key), 'xmlns', namespace)
      end
      return arg.inject({}) do |result, (k, v)|
        if (k == :attributes!)
          result[k] = v
        else
          subfield = (field_type.nil?) ? nil :
              get_field_by_name(field_type[:fields], k)
          # Here we will give up if the field is unknown. For full validation
          # we have to handle nil here and also take into consideration user-
          # specified xsi:type.
          subtype_name, subtype = if subfield and subfield.include?(:type)
            subtype_name = subfield[:type]
            subtype = (subtype_name.nil?) ? nil :
                get_service_registry.get_type_signature(subtype_name)
            [subtype_name, subtype]
          end
          # In case of non-default namespace, the children should be in
          # overriden namespace but the node has to be in the default.
          prefixed_key = (subtype and subtype[:ns]) ? prefix_key(k) : k
          result[prefixed_key] = validate_arg(v, result, k, subtype_name)
        end
        result
      end
    end

    # Adds ":attributes!" record for Savon to specify xsi:type.
    def add_xsi_type(parent, key, xsi_type)
      add_attribute(parent, key, 'xsi:type', xsi_type)
    end

    # Adds Savon attribute for given node, key, name and value.
    def add_attribute(node, key, name, value)
      node[:attributes!] ||= {}
      node[:attributes!][key] ||= {}
      node[:attributes!][key][name] ||= []
      node[:attributes!][key][name] << value
    end

    # Prefixes default namespace.
    def prefix_key(key)
      return "%s:%s" % [DEFAULT_NAMESPACE, key.to_s.lower_camelcase]
    end

    # Executes each handler to generate SOAP headers.
    def set_headers(soap, args)
      @headerhandler.each do |handler|
        handler.prepare_request(@client.http, soap, args)
      end
    end

    # Checks for errors in response and raises appropriate exception.
    def handle_errors(response)
      if response.soap_fault?
        exception = exception_for_soap_fault(response)
        raise exception
      end
      if response.http_error?
        raise AdsCommon::Errors::HttpError,
            "HTTP Error occurred: %s" % response.http_error
      end
    end

    # Finds an exception object for a given response.
    def exception_for_soap_fault(response)
      begin
        fault = response[:fault]
        if fault[:detail] and fault[:detail][:api_exception_fault]
          exception_fault = fault[:detail][:api_exception_fault]
          exception_name = exception_fault[:application_exception_type]
          exception_class = get_module().const_get(exception_name)
          return exception_class.new(exception_fault)
        elsif fault[:faultstring]
          fault_message = fault[:faultstring]
          return AdsCommon::Errors::ApiException.new(
              "Unknown exception with error: %s" % fault_message)
        else
          raise ArgumentError.new(fault.to_s)
        end
      rescue Exception => e
        return AdsCommon::Errors::ApiException.new(
            "Failed to resolve exception (%s), SOAP fault: %s" %
            [e.message, response.soap_fault])
      end
    end

    # Extracts the finest results possible for the given result. Returns the
    # response itself in worst case (contents unknown).
    def extract_result(response, action_name)
      method = get_service_registry.get_method_signature(action_name)
      action = method[:output][:name].to_sym
      result = response.to_hash
      result = result[action] if result.include?(action)
      return normalize_output(result, method)
    end

    # Normalizes output starting with root node "rval".
    def normalize_output(output_data, method_definition)
      fields_list = method_definition[:output][:fields]
      result = normalize_output_field(output_data, fields_list, :rval)
      return result[:rval]
    end

    # Normalizes one field of a given data recursively.
    # Args:
    #  - output_data: XML data to normalize
    #  - fields_list: expected list of fields from signature
    #  - field_name: specifies field name to normalize
    def normalize_output_field(output_data, fields_list, field_name)
      return nil if output_data.nil?
      field_definition = get_field_by_name(fields_list, field_name)
      field_sym = field_name.to_sym
      output_data[field_sym] = normalize_type(output_data[field_sym],
          field_definition)

      sub_type = get_service_registry.get_type_signature(
          field_definition[:type])
      if sub_type
        sub_type[:fields] += implode_parent(sub_type)
        if sub_type[:fields]
          # go recursive
          sub_type[:fields].each do |sub_type_field|
            if output_data[field_sym].is_a?(Array)
              items_list = output_data[field_sym]
              output_data[field_sym] = []
              items_list.each do |item|
                output_data[field_sym] <<
                    normalize_output_field(item, sub_type_field,
                                           sub_type_field[:name])
              end
            else
              output_data[field_sym] =
                  normalize_output_field(output_data[field_sym], sub_type_field,
                                         sub_type_field[:name])
            end
          end
        end
      end
      return output_data
    end

    # Converts XML input string into a native format.
    def normalize_type(data, field)
      type_name = field[:type]
      result = case data
        when Array
          data.map {|item| normalize_item(type_name, item)}
        else
          normalize_item(type_name, data)
      end
      # If field signature allows an array, forcing array structure even for one
      # item.
      if !field[:min_occurs].nil? and
          (field[:max_occurs].nil? or field[:max_occurs] > 1)
        result = arrayize(result)
      end
      return result
    end

    # Converts one leaf item to a built-in type.
    def normalize_item(type_name, item)
      return (item.nil?) ? item :
          case type_name
            when 'long', 'int' then Integer(item)
            when 'double' then Float(item)
            when 'boolean' then item.kind_of?(String) ?
                item.casecmp('true') == 0 : item
            else item
          end
    end

    # Finds a field in a list by its name.
    def get_field_by_name(fields_list, name)
      fields_array = arrayize(fields_list)
      index = fields_array.find_index {|field| field[:name].eql?(name)}
      return (index.nil?) ? nil : fields_array.at(index)
    end

    # Makes sure object is an array.
    def arrayize(object)
      return [] if object.nil?
      return object.is_a?(Array) ? object : [object]
    end

    # Converts Time to a hash for XML marshalling.
    def time_to_xml_hash(time)
      return {
          :hour => time.hour, :minute => time.min, :second => time.sec,
          :date => {:year => time.year, :month => time.month, :day => time.day}
      }
    end

    # Returns all inherited fields of superclasses for given type.
    def implode_parent(data_type)
      result = []
      if data_type and data_type[:base]
        parent_type = get_service_registry.get_type_signature(data_type[:base])
        result += parent_type[:fields] if parent_type[:fields]
        result += implode_parent(parent_type) if parent_type[:base]
      end
      return result
    end

    # Returns copy of object and its sub-objects ("deep" copy).
    def deep_copy(data)
      return Marshal.load(Marshal.dump(data))
    end
  end
end