require 'orient_db_client/network_message'
require 'orient_db_client/version'
require 'bindata'

module OrientDbClient
  module Protocols
    class Protocol15 < Protocol7
      VERSION = 15

      module Commands
        class ConfigGet < BinData::Record
          endian :big
          int8            :operation,     :value => Protocol7::Operations::CONFIG_GET
          int32           :session
          protocol_string :config_name
        end

        class DbCreate < BinData::Record
          endian :big

          int8            :operation,       :value => Protocol7::Operations::DB_CREATE
          int32           :session

          protocol_string :database
          protocol_string :database_type
          protocol_string :storage_type
        end

        class DbOpen < BinData::Record
          endian :big

          int8            :operation,       :value => Protocol7::Operations::DB_OPEN
          int32           :session,         :value => Protocol7::NEW_SESSION

          protocol_string :driver_name,     :value => Protocol7::DRIVER_NAME
          protocol_string :driver_version,  :value => Protocol7::DRIVER_VERSION
          int16           :protocol_version
          protocol_string :client_id
          protocol_string :database_name
          protocol_string :database_type
          protocol_string :user_name
          protocol_string :user_password
        end

        class RecordLoad15 < BinData::Record
          endian :big

          int8            :operation,         :value => Protocol7::Operations::RECORD_LOAD
          int32           :session

          int16           :cluster_id
          int64           :cluster_position
          protocol_string :fetch_plan
          int8            :ignore_cache,      :initial_value => 1
        end

        class RecordCreate15 < BinData::Record
          endian :big

          int8              :operation,       :value => Protocol7::Operations::RECORD_CREATE
          int32             :session
          int32             :datasegment_id,   :value => -1
          int16             :cluster_id
          protocol_string   :record_content
          int8              :record_type,     :value => Protocol7::RecordTypes::DOCUMENT
          int8              :mode,            :value => Protocol7::SyncModes::SYNC
        end

      end

      def self.command(socket, session, command, options = {})
        options[:query_class_name].tap do |qcn|
          if qcn.is_a?(Symbol)
            qcn = case qcn
            when :query then 'q'
            when :command then 'c'
            end
          end

          if qcn.nil? || qcn == 'com.orientechnologies.orient.core.sql.query.OSQLSynchQuery'
            qcn = 'q'
          end

          options[:query_class_name] = qcn
        end

        super socket, session, command, options
      end

      def self.db_create(socket, session, database, options = {})
        if options.is_a?(String)
          options = { :storage_type => options }
        end

        options = {
          :database_type => 'document'
        }.merge(options)

        super
      end

      def self.read_clusters(socket)
        clusters = []

        num_clusters = read_short(socket)
        (num_clusters).times do |x|
          cluster =
          {
            :name   => read_string(socket),
            :id   => read_short(socket),
            :type   => read_string(socket),
            :data_segment => read_short(socket)
          }
          clusters << cluster

        end

        clusters
      end

      def self.read_record_load(socket)
        result = nil

        status = read_byte(socket)
        
        while (status != PayloadStatuses::NO_RECORDS)
          case status
            when PayloadStatuses::RESULTSET
              record = record || read_record(socket)
              case record[:record_type]
            when 'd'.ord
              result = result || record
              result[:document] = deserializer.deserialize(record[:bytes])[:document]
            else
              raise "Unsupported record type: #{record[:record_type]}"
            end
          else
            raise "Unsupported payload status: #{status}"
          end
          status = read_byte(socket)
        end

        result
      end

      def self.read_db_open(socket)
        session = read_integer(socket)
        clusters = read_clusters(socket)
        { :session      => session,
          :clusters     => clusters,
          :cluster_config   => read_string(socket)  }
      end

      def self.record_create(socket, session, cluster_id, record)
        command = Commands::RecordCreate15.new :session => session,
        :cluster_id => cluster_id,
        :record_content => serializer.serialize(record)
        command.write(socket)

        read_response(socket)

        { :session      => read_integer(socket),
          :message_content  => read_record_create(socket).merge({ :cluster_id => cluster_id }) }
      end

      def self.db_open(socket, database, options = {})
        command = Commands::DbOpen.new :protocol_version => self.version,
        :database_name => database,
        :database_type => options[:database_type] || 'document',
        :user_name => options[:user],
        :user_password => options[:password]
        command.write(socket)

        read_response(socket)

        { :session          => read_integer(socket),
          :message_content  => read_db_open(socket) }
      end

      def self.config_get(socket, session, config_name)
        config = Commands::ConfigGet.new :session => session,
        :config_name => config_name

        config.write(socket)

        response = read_response(socket)
        { :session => read_integer(socket),
          :value => read_string(socket) }

      end

      def self.record_load(socket, session, rid, options = {})
        command = Commands::RecordLoad15.new :session => session,
                                             :cluster_id => rid.cluster_id,
                                             :cluster_position => rid.cluster_position
                                             # :ignore_cache => options[:ignore_cache] === true ? 1 : 0
                                             
        command.write(socket)

        read_response(socket)
        
        { :session          => read_integer(socket),
          :message_content  => read_record_load(socket) }
      end
      
      def self.read_record_create(socket)
        { :cluster_position => read_long(socket),
          :record_version => read_integer(socket) }
      end

      private

      def self.make_db_create_command(*args)
        session = args.shift
        database = args.shift
        options = args.shift

        Commands::DbCreate.new :session => session,
        :database => database,
        :database_type => options[:database_type].to_s,
        :storage_type => options[:storage_type]
      end

    end
  end
end